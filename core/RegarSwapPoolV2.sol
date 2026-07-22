// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @dev Minimal ERC20 interface for interacting with pool tokens.
 */
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @dev Minimal SafeERC20-style helpers.
 *      - Tolerates tokens that don't return a bool from transfer/transferFrom
 *        (e.g. USDT), which would otherwise make `require(token.transfer(...))`
 *        revert even on a successful transfer.
 *      - `safeTransferFromReceived` measures the ACTUAL balance delta instead
 *        of trusting the requested amount, so fee-on-transfer / deflationary
 *        tokens can't desync the pool's internal reserve accounting.
 */
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }

    /// @dev Pulls `amount` from `from` into this contract and returns what the
    ///      contract's balance ACTUALLY increased by (handles fee-on-transfer
    ///      tokens correctly). Reverts if nothing was received.
    function safeTransferFromReceived(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balBefore = token.balanceOf(address(this));
        safeTransferFrom(token, from, address(this), amount);
        uint256 balAfter = token.balanceOf(address(this));
        received = balAfter - balBefore;
        require(received > 0, "SafeERC20: zero amount received");
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrancy: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/**
 * @title RegarSwapPoolV2
 * @dev Drop-in replacement for RegarSwapPool. Function names and signatures
 *      match the ABI already used by the frontend (poolDepositABI), so only
 *      CONTRACT_POOL_ADDRESS needs to change — no frontend rewiring needed.
 *
 *      Key fixes vs the original contract:
 *      - Every pair (tokenA/tokenB) has ISOLATED reserves, LP shares and fee
 *        accounting via a `pairId`. Draining or manipulating one pair cannot
 *        touch another pair's funds.
 *      - executeSwap() output is DERIVED from the constant-product invariant
 *        (x*y=k) plus fee — callers can no longer dictate an arbitrary
 *        amountOut.
 *      - LPs get real on-chain shares (getLpPosition), can withdraw a % of
 *        their own position (removeLiquidity), and fees accumulate in a
 *        SEPARATE claimable bucket so claimFees() never touches principal.
 */
contract RegarSwapPoolV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    address public pendingOwner;

    uint256 public constant FEE_BPS = 30;        // 0.30% total swap fee
    uint256 public constant LP_FEE_BPS = 25;      // 0.25% of the 0.30% goes to LPs
    uint256 public constant PROTOCOL_FEE_BPS = 5; // 0.05% goes to protocol (owner)
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    struct Pair {
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalShares;
        uint256 feePerShareA; // cumulative LP fee per share, scaled by PRECISION
        uint256 feePerShareB;
        uint256 protocolFeeA; // accrued, owner-claimable
        uint256 protocolFeeB;
        bool exists;
        string name;
    }

    mapping(bytes32 => Pair) public pairs;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => mapping(address => uint256)) private feeSnapshotA;
    mapping(bytes32 => mapping(address => uint256)) private feeSnapshotB;
    mapping(bytes32 => mapping(address => uint256)) public claimableFeeA;
    mapping(bytes32 => mapping(address => uint256)) public claimableFeeB;
    bytes32[] public allPairIds;

    event PairAdded(bytes32 indexed pairId, address indexed tokenA, address indexed tokenB, string name);
    event LiquidityAdded(bytes32 indexed pairId, address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event LiquidityRemoved(bytes32 indexed pairId, address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event SwapExecuted(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event FeesClaimed(bytes32 indexed pairId, address indexed provider, uint256 feeA, uint256 feeB);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProtocolFeesClaimed(bytes32 indexed pairId, address indexed owner, uint256 feeA, uint256 feeB);

    modifier onlyOwner() {
        require(msg.sender == owner, "Auth: only owner");
        _;
    }

    modifier ensure(uint256 deadline) {
        require(block.timestamp <= deadline, "Expired: deadline passed");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────
    // Ownership transfer — 2-step (propose then accept) so a typo'd or
    // unreachable address can never accidentally lock the owner role.
    // ─────────────────────────────────────────────────────────────────
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Auth: zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Auth: not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @dev Irreversible. Only use if you deliberately want NO owner left
    ///      (addPair/claimProtocolFees become permanently uncallable).
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }

    // ─────────────────────────────────────────────────────────────────
    // Pair identity — canonical ordering so getPairId(A,B) == getPairId(B,A)
    // ─────────────────────────────────────────────────────────────────
    function getPairId(address tokenA, address tokenB) public pure returns (bytes32) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(t0, t1));
    }

    function getAllPairs() external view returns (bytes32[] memory) {
        return allPairIds;
    }

    function getPairInfo(bytes32 pairId)
        external
        view
        returns (address tokenA, address tokenB, uint256 reserveA, uint256 reserveB, uint256 totalShares, string memory name)
    {
        Pair storage p = pairs[pairId];
        return (p.tokenA, p.tokenB, p.reserveA, p.reserveB, p.totalShares, p.name);
    }

    /**
     * @dev Owner-gated: register a new tradable pair. Restricting this
     *      prevents spam/fake pairs (the original contract had no access
     *      control on anything at all).
     */
    function addPair(address tokenA, address tokenB, string calldata name) external onlyOwner {
        require(tokenA != tokenB, "Pair: identical tokens");
        require(tokenA != address(0) && tokenB != address(0), "Pair: zero address");
        bytes32 pairId = getPairId(tokenA, tokenB);
        require(!pairs[pairId].exists, "Pair: already exists");

        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pairs[pairId] = Pair({
            tokenA: t0,
            tokenB: t1,
            reserveA: 0,
            reserveB: 0,
            totalShares: 0,
            feePerShareA: 0,
            feePerShareB: 0,
            protocolFeeA: 0,
            protocolFeeB: 0,
            exists: true,
            name: name
        });
        allPairIds.push(pairId);
        emit PairAdded(pairId, t0, t1, name);
    }

    // ─────────────────────────────────────────────────────────────────
    // Internal fee settlement — always run before shares change so past
    // fees are locked in at the OLD share count, never diluted or lost.
    // ─────────────────────────────────────────────────────────────────
    function _settleFees(bytes32 pairId, address user) internal {
        Pair storage p = pairs[pairId];
        uint256 shares = lpShares[pairId][user];
        if (shares > 0) {
            uint256 owedA = (shares * (p.feePerShareA - feeSnapshotA[pairId][user])) / PRECISION;
            uint256 owedB = (shares * (p.feePerShareB - feeSnapshotB[pairId][user])) / PRECISION;
            if (owedA > 0) claimableFeeA[pairId][user] += owedA;
            if (owedB > 0) claimableFeeB[pairId][user] += owedB;
        }
        feeSnapshotA[pairId][user] = p.feePerShareA;
        feeSnapshotB[pairId][user] = p.feePerShareB;
    }

    function _pendingFees(bytes32 pairId, address user) internal view returns (uint256 pendingA, uint256 pendingB) {
        Pair storage p = pairs[pairId];
        uint256 shares = lpShares[pairId][user];
        pendingA = claimableFeeA[pairId][user] + (shares * (p.feePerShareA - feeSnapshotA[pairId][user])) / PRECISION;
        pendingB = claimableFeeB[pairId][user] + (shares * (p.feePerShareB - feeSnapshotB[pairId][user])) / PRECISION;
    }

    // ─────────────────────────────────────────────────────────────────
    // Add liquidity — pulls tokens at the pool's current ratio (first
    // deposit sets the ratio) and mints shares proportional to it.
    // ─────────────────────────────────────────────────────────────────
    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB, uint256 deadline)
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 shares)
    {
        bytes32 pairId = getPairId(tokenA, tokenB);
        Pair storage p = pairs[pairId];
        require(p.exists, "Pair: not registered");
        require(amountA > 0 && amountB > 0, "Pair: zero amount");

        _settleFees(pairId, msg.sender);

        // Orient amounts to the pair's canonical tokenA/tokenB ordering
        (uint256 amtA, uint256 amtB) = tokenA == p.tokenA ? (amountA, amountB) : (amountB, amountA);

        uint256 usedA = amtA;
        uint256 usedB = amtB;
        if (p.reserveA > 0 && p.reserveB > 0) {
            uint256 optimalB = (amtA * p.reserveB) / p.reserveA;
            if (optimalB <= amtB) {
                usedB = optimalB;
            } else {
                usedA = (amtB * p.reserveA) / p.reserveB;
            }
        }

        // Pull tokens and use the ACTUAL amount received (not the requested
        // amount) so fee-on-transfer / deflationary tokens can never desync
        // reserveA/reserveB from what the pool truly holds.
        usedA = IERC20(p.tokenA).safeTransferFromReceived(msg.sender, usedA);
        usedB = IERC20(p.tokenB).safeTransferFromReceived(msg.sender, usedB);

        if (p.totalShares == 0) {
            shares = _sqrt(usedA * usedB) - MINIMUM_LIQUIDITY;
            p.totalShares += MINIMUM_LIQUIDITY; // locked forever, standard AMM practice
        } else {
            shares = _min((usedA * p.totalShares) / p.reserveA, (usedB * p.totalShares) / p.reserveB);
        }
        require(shares > 0, "Pair: insufficient shares minted");

        p.reserveA += usedA;
        p.reserveB += usedB;
        p.totalShares += shares;
        lpShares[pairId][msg.sender] += shares;

        emit LiquidityAdded(pairId, msg.sender, usedA, usedB, shares);
    }

    /**
     * @dev sharePct is a 0-100 percentage of the CALLER'S OWN position
     *      (matches the frontend slider), not of the whole pool.
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 sharePct,
        uint256 minAmountA,
        uint256 minAmountB,
        uint256 deadline
    )
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        require(sharePct > 0 && sharePct <= 100, "Pair: invalid percentage");
        bytes32 pairId = getPairId(tokenA, tokenB);
        Pair storage p = pairs[pairId];
        require(p.exists, "Pair: not registered");

        _settleFees(pairId, msg.sender);

        uint256 userShares = lpShares[pairId][msg.sender];
        require(userShares > 0, "Pair: no position");

        uint256 sharesToBurn = (userShares * sharePct) / 100;
        require(sharesToBurn > 0, "Pair: nothing to withdraw");

        amountA = (sharesToBurn * p.reserveA) / p.totalShares;
        amountB = (sharesToBurn * p.reserveB) / p.totalShares;

        // Slippage protection: caller specifies these in tokenA/tokenB order
        // (the pair's canonical order), same as minAmountA/minAmountB naming.
        (uint256 checkMinA, uint256 checkMinB) = tokenA == p.tokenA ? (minAmountA, minAmountB) : (minAmountB, minAmountA);
        require(amountA >= checkMinA && amountB >= checkMinB, "Pair: slippage exceeded");

        lpShares[pairId][msg.sender] -= sharesToBurn;
        p.totalShares -= sharesToBurn;
        p.reserveA -= amountA;
        p.reserveB -= amountB;

        IERC20(p.tokenA).safeTransfer(msg.sender, amountA);
        IERC20(p.tokenB).safeTransfer(msg.sender, amountB);

        emit LiquidityRemoved(pairId, msg.sender, amountA, amountB, sharesToBurn);

        // tokenA/tokenB return values oriented to caller's original argument order
        if (tokenA != p.tokenA) (amountA, amountB) = (amountB, amountA);
    }

    /**
     * @dev Pays out ONLY the accumulated fee bucket — principal/shares are
     *      never touched here, matching the UI copy: "Claiming sends them
     *      directly to your wallet without touching your deposited liquidity."
     */
    function claimFees(address tokenA, address tokenB) external nonReentrant returns (uint256 feeA, uint256 feeB) {
        bytes32 pairId = getPairId(tokenA, tokenB);
        Pair storage p = pairs[pairId];
        require(p.exists, "Pair: not registered");

        _settleFees(pairId, msg.sender);

        feeA = claimableFeeA[pairId][msg.sender];
        feeB = claimableFeeB[pairId][msg.sender];
        require(feeA > 0 || feeB > 0, "Pair: no fees to claim");

        claimableFeeA[pairId][msg.sender] = 0;
        claimableFeeB[pairId][msg.sender] = 0;

        if (feeA > 0) IERC20(p.tokenA).safeTransfer(msg.sender, feeA);
        if (feeB > 0) IERC20(p.tokenB).safeTransfer(msg.sender, feeB);

        emit FeesClaimed(pairId, msg.sender, feeA, feeB);
    }

    function getLpPosition(address user, address tokenA, address tokenB)
        external
        view
        returns (
            uint256 shares,
            uint256 totalShares,
            uint256 poolSharePct,
            uint256 valueA,
            uint256 valueB,
            uint256 pendingFeeA,
            uint256 pendingFeeB
        )
    {
        bytes32 pairId = getPairId(tokenA, tokenB);
        Pair storage p = pairs[pairId];
        shares = lpShares[pairId][user];
        totalShares = p.totalShares;
        poolSharePct = totalShares > 0 ? (shares * BPS_DENOMINATOR) / totalShares : 0; // in bps (10000 = 100%)
        valueA = totalShares > 0 ? (shares * p.reserveA) / totalShares : 0;
        valueB = totalShares > 0 ? (shares * p.reserveB) / totalShares : 0;
        (pendingFeeA, pendingFeeB) = _pendingFees(pairId, user);
    }

    // ─────────────────────────────────────────────────────────────────
    // Swap — amountOut is DERIVED from the invariant, never supplied by
    // the caller. This is the fix for the original contract's critical
    // flaw (anyone could previously drain the pool by naming their own
    // amountOut).
    // ─────────────────────────────────────────────────────────────────
    struct SwapResult {
        uint256 receivedIn;
        uint256 lpFee;
        uint256 protocolFee;
        uint256 amountInAfterFee;
        uint256 amountOut;
        bool inIsA;
    }

    function _calcSwap(bytes32 pairId, address tokenIn, uint256 amountIn, uint256 minOut)
        internal
        returns (SwapResult memory r)
    {
        Pair storage p = pairs[pairId];
        r.inIsA = tokenIn == p.tokenA;
        (uint256 reserveIn, uint256 reserveOut) = r.inIsA ? (p.reserveA, p.reserveB) : (p.reserveB, p.reserveA);

        r.receivedIn = IERC20(tokenIn).safeTransferFromReceived(msg.sender, amountIn);
        r.lpFee = (r.receivedIn * LP_FEE_BPS) / BPS_DENOMINATOR;
        r.protocolFee = (r.receivedIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        r.amountInAfterFee = r.receivedIn - r.lpFee - r.protocolFee;

        r.amountOut = (r.amountInAfterFee * reserveOut) / (reserveIn + r.amountInAfterFee);
        require(r.amountOut > 0 && r.amountOut >= minOut, "Swap: slippage exceeded");
        require(r.amountOut < reserveOut, "Swap: insufficient liquidity");
    }

    function _applySwap(bytes32 pairId, SwapResult memory r) internal {
        Pair storage p = pairs[pairId];
        if (p.totalShares > 0) {
            if (r.inIsA) {
                p.feePerShareA += (r.lpFee * PRECISION) / p.totalShares;
            } else {
                p.feePerShareB += (r.lpFee * PRECISION) / p.totalShares;
            }
        }
        if (r.inIsA) {
            p.reserveA += r.amountInAfterFee + r.lpFee;
            p.reserveB -= r.amountOut;
            p.protocolFeeA += r.protocolFee;
        } else {
            p.reserveB += r.amountInAfterFee + r.lpFee;
            p.reserveA -= r.amountOut;
            p.protocolFeeB += r.protocolFee;
        }
    }

    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Swap: zero input");
        bytes32 pairId = getPairId(tokenIn, tokenOut);
        require(pairs[pairId].exists, "Swap: pair not registered");

        SwapResult memory r = _calcSwap(pairId, tokenIn, amountIn, minOut);
        _applySwap(pairId, r);

        IERC20(tokenOut).safeTransfer(msg.sender, r.amountOut);
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, r.receivedIn, r.amountOut);
        amountOut = r.amountOut;
    }

    function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 fee)
    {
        bytes32 pairId = getPairId(tokenIn, tokenOut);
        Pair storage p = pairs[pairId];
        if (!p.exists) return (0, 0);

        bool inIsA = tokenIn == p.tokenA;
        (uint256 reserveIn, uint256 reserveOut) = inIsA ? (p.reserveA, p.reserveB) : (p.reserveB, p.reserveA);
        if (reserveIn == 0 || reserveOut == 0) return (0, 0);

        fee = (amountIn * FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - fee;
        amountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee);
    }

    // ─────────────────────────────────────────────────────────────────
    // Owner: claim accrued protocol fee slice (separate from LP fees)
    // ─────────────────────────────────────────────────────────────────
    function claimProtocolFees(address tokenA, address tokenB) external onlyOwner nonReentrant returns (uint256 feeA, uint256 feeB) {
        bytes32 pairId = getPairId(tokenA, tokenB);
        Pair storage p = pairs[pairId];
        require(p.exists, "Pair: not registered");

        feeA = p.protocolFeeA;
        feeB = p.protocolFeeB;
        p.protocolFeeA = 0;
        p.protocolFeeB = 0;

        if (feeA > 0) IERC20(p.tokenA).safeTransfer(owner, feeA);
        if (feeB > 0) IERC20(p.tokenB).safeTransfer(owner, feeB);

        emit ProtocolFeesClaimed(pairId, owner, feeA, feeB);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
