// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @dev Minimal ERC20 interface (includes approve, since the vault must
 *      approve the Pool to pull tokens back OUT of the vault).
 */
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @dev Interface for the already-deployed RegarSwapPoolV2. Only the
 *      functions the vault actually calls are declared here.
 */
interface IRegarSwapPoolV2 {
    function getPairId(address tokenA, address tokenB) external pure returns (bytes32);

    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB, uint256 deadline)
        external
        returns (uint256 shares);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 sharePct,
        uint256 minAmountA,
        uint256 minAmountB,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function claimFees(address tokenA, address tokenB) external returns (uint256 feeA, uint256 feeB);

    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 amountOut);

    function lpShares(bytes32 pairId, address user) external view returns (uint256);

    function getPairInfo(bytes32 pairId)
        external
        view
        returns (
            address tokenA,
            address tokenB,
            uint256 reserveA,
            uint256 reserveB,
            uint256 totalShares,
            string memory name
        );
}

/**
 * @dev Minimal SafeERC20-style helpers, same defensive pattern as
 *      RegarSwapPoolV2: tolerate non-bool-returning tokens, measure ACTUAL
 *      balance deltas for fee-on-transfer tokens, and reset-then-set
 *      allowance for tokens (like older USDT) that reject a nonzero ->
 *      nonzero approve() change.
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

    function safeTransferFromReceived(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balBefore = token.balanceOf(address(this));
        safeTransferFrom(token, from, address(this), amount);
        uint256 balAfter = token.balanceOf(address(this));
        received = balAfter - balBefore;
        require(received > 0, "SafeERC20: zero amount received");
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        if (amount > 0) {
            // best-effort reset; ignore failure since some tokens don't need it
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        }
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
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
 * @title RegarVault
 * @dev Auto-compounding vault built ON TOP OF RegarSwapPoolV2 — it does not
 *      modify the Pool contract in any way, it only calls its public
 *      functions like any other external caller.
 *
 *      WHY A SEPARATE SHARE SYSTEM IS NEEDED:
 *      RegarSwapPoolV2's `lpShares` is a non-transferable mapping keyed to
 *      msg.sender — there is no ERC20 LP receipt token. So this vault
 *      becomes the Pool's LP of record itself (all deposits are pooled
 *      under `address(this)`), and tracks each user's proportional claim
 *      on the vault's own LP position via an internal `userVaultShares`
 *      ledger. Depositing/withdrawing from the vault never changes who the
 *      Pool thinks the LP is (always this contract) — only vault-internal
 *      bookkeeping changes.
 *
 *      AUTO-COMPOUND MECHANIC:
 *      harvest() claims accumulated swap fees from the Pool, takes a
 *      performance fee slice for the treasury, swaps the remainder to the
 *      pool's current ratio, and re-adds it as liquidity — increasing the
 *      vault's total LP position WITHOUT minting new vault shares. Existing
 *      shares simply become worth more LP (and more of both underlying
 *      tokens) over time.
 *
 *      KNOWN PRECISION LIMITATION:
 *      RegarSwapPoolV2.removeLiquidity() only accepts a whole 0-100 percent
 *      of the CALLER'S (the vault's) own LP position — there is no
 *      amount-based withdrawal. This vault converts a user's requested
 *      vault-share amount into that whole-percent, rounding DOWN. This
 *      means very small fractional withdrawal requests can round to 0%
 *      (and revert) or leave a tiny amount of dust still credited to the
 *      user's vault share balance. This is a Pool-level constraint, not a
 *      vault bug; it can only be fully fixed by adding an amount-based
 *      removeLiquidity variant to the Pool in a future version.
 */
contract RegarVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    address public pendingOwner;
    address public treasury;

    IRegarSwapPoolV2 public immutable pool;

    uint256 public constant PERFORMANCE_FEE_BPS = 500; // 5% of harvested fees -> treasury
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MINIMUM_VAULT_SHARES = 1000;

    struct VaultPair {
        address tokenA; // canonical order (tokenA < tokenB), mirrors the Pool's own ordering
        address tokenB;
        uint256 totalVaultShares;
        bool exists;
    }

    /// @dev Groups withdraw call-site arguments to avoid stack-too-deep in helpers.
    struct WithdrawParams {
        uint256 sharesToBurn;
        uint256 userShares;
        uint256 minAmountA;
        uint256 minAmountB;
        address callerTokenA;
        uint256 deadline;
    }

    mapping(bytes32 => VaultPair) public vaultPairs;
    mapping(bytes32 => mapping(address => uint256)) public userVaultShares;
    bytes32[] public allVaultPairIds;

    event VaultPairAdded(bytes32 indexed pairId, address indexed tokenA, address indexed tokenB);
    event Deposited(bytes32 indexed pairId, address indexed user, uint256 amountA, uint256 amountB, uint256 vaultShares);
    event Withdrawn(bytes32 indexed pairId, address indexed user, uint256 amountA, uint256 amountB, uint256 vaultShares);
    event Harvested(bytes32 indexed pairId, address indexed caller, uint256 feeA, uint256 feeB, uint256 lpMinted);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasuryUpdated(address indexed newTreasury);

    modifier onlyOwner() {
        require(msg.sender == owner, "Auth: only owner");
        _;
    }

    modifier ensure(uint256 deadline) {
        require(block.timestamp <= deadline, "Expired: deadline passed");
        _;
    }

    constructor(address poolAddress, address treasuryAddress) {
        require(poolAddress != address(0), "Vault: zero pool");
        require(treasuryAddress != address(0), "Vault: zero treasury");
        owner = msg.sender;
        pool = IRegarSwapPoolV2(poolAddress);
        treasury = treasuryAddress;
    }

    // ─────────────────────────────────────────────────────────────────
    // Ownership transfer — same 2-step pattern as RegarSwapPoolV2.
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

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Vault: zero treasury");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    // ─────────────────────────────────────────────────────────────────
    // Vault pair registration — mirrors the Pool's pair identity so the
    // frontend can reuse the same tokenA/tokenB inputs it already has.
    // ─────────────────────────────────────────────────────────────────
    function getVaultPairId(address tokenA, address tokenB) public pure returns (bytes32) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(t0, t1));
    }

    function addVaultPair(address tokenA, address tokenB) external onlyOwner {
        require(tokenA != tokenB, "Vault: identical tokens");
        require(tokenA != address(0) && tokenB != address(0), "Vault: zero address");
        bytes32 pairId = getVaultPairId(tokenA, tokenB);
        require(!vaultPairs[pairId].exists, "Vault: pair already added");

        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        vaultPairs[pairId] = VaultPair({tokenA: t0, tokenB: t1, totalVaultShares: 0, exists: true});
        allVaultPairIds.push(pairId);
        emit VaultPairAdded(pairId, t0, t1);
    }

    function getAllVaultPairs() external view returns (bytes32[] memory) {
        return allVaultPairIds;
    }

    /// @dev How much LP the vault itself currently owns in the Pool for this pair.
    function poolLpShares(bytes32 pairId) public view returns (uint256) {
        VaultPair storage vp = vaultPairs[pairId];
        bytes32 poolPairId = pool.getPairId(vp.tokenA, vp.tokenB);
        return pool.lpShares(poolPairId, address(this));
    }

    // ─────────────────────────────────────────────────────────────────
    // Deposit — pulls tokens from user, adds them as liquidity to the
    // Pool (vault becomes the LP of record), mints vault shares
    // proportional to the LP actually gained.
    // ─────────────────────────────────────────────────────────────────
    function deposit(address tokenA, address tokenB, uint256 amountA, uint256 amountB, uint256 deadline)
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 vaultShares)
    {
        bytes32 pairId = getVaultPairId(tokenA, tokenB);
        VaultPair storage vp = vaultPairs[pairId];
        require(vp.exists, "Vault: pair not registered");
        require(amountA > 0 && amountB > 0, "Vault: zero amount");

        (uint256 amtA, uint256 amtB) = tokenA == vp.tokenA ? (amountA, amountB) : (amountB, amountA);

        // Measure actual received to stay correct for fee-on-transfer tokens
        amtA = IERC20(vp.tokenA).safeTransferFromReceived(msg.sender, amtA);
        amtB = IERC20(vp.tokenB).safeTransferFromReceived(msg.sender, amtB);

        uint256 lpBefore = poolLpShares(pairId);

        IERC20(vp.tokenA).safeApprove(address(pool), amtA);
        IERC20(vp.tokenB).safeApprove(address(pool), amtB);
        pool.addLiquidity(vp.tokenA, vp.tokenB, amtA, amtB, deadline);

        uint256 lpAfter = poolLpShares(pairId);
        uint256 lpMinted = lpAfter - lpBefore;
        require(lpMinted > 0, "Vault: no LP minted");

        if (vp.totalVaultShares == 0) {
            require(lpMinted > MINIMUM_VAULT_SHARES, "Vault: deposit too small");
            vaultShares = lpMinted - MINIMUM_VAULT_SHARES;
            vp.totalVaultShares += MINIMUM_VAULT_SHARES; // locked forever, same pattern as the Pool
        } else {
            // mint proportional to what this deposit actually added, relative
            // to the LP the vault held immediately BEFORE this deposit
            vaultShares = (lpMinted * vp.totalVaultShares) / lpBefore;
        }
        require(vaultShares > 0, "Vault: insufficient shares minted");

        vp.totalVaultShares += vaultShares;
        userVaultShares[pairId][msg.sender] += vaultShares;

        emit Deposited(pairId, msg.sender, amtA, amtB, vaultShares);
    }

    // ─────────────────────────────────────────────────────────────────
    // Withdraw — burns the caller's vault shares, removes the
    // corresponding LP from the Pool, and forwards the resulting tokens.
    // See KNOWN PRECISION LIMITATION note above regarding sharePct rounding.
    // ─────────────────────────────────────────────────────────────────
    function withdraw(
        address tokenA,
        address tokenB,
        uint256 sharesToBurn,
        uint256 minAmountA,
        uint256 minAmountB,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        bytes32 pairId = getVaultPairId(tokenA, tokenB);
        require(vaultPairs[pairId].exists, "Vault: pair not registered");
        uint256 userShares = userVaultShares[pairId][msg.sender];
        require(sharesToBurn > 0 && sharesToBurn <= userShares, "Vault: invalid share amount");

        WithdrawParams memory wp = WithdrawParams({
            sharesToBurn: sharesToBurn,
            userShares: userShares,
            minAmountA: minAmountA,
            minAmountB: minAmountB,
            callerTokenA: tokenA,
            deadline: deadline
        });
        (amountA, amountB) = _doWithdraw(pairId, wp, tokenA, tokenB);
    }

    /// @dev Executes the LP removal, share accounting, and token transfers.
    ///      Separated from withdraw() so each frame has a manageable stack.
    function _doWithdraw(
        bytes32 pairId,
        WithdrawParams memory wp,
        address tokenA,
        address tokenB
    ) private returns (uint256 amountA, uint256 amountB) {
        VaultPair storage vp = vaultPairs[pairId];

        uint256 actualSharesBurned;
        (amountA, amountB, actualSharesBurned) = _removeLiquidityForShares(vp, pairId, wp);

        userVaultShares[pairId][msg.sender] = wp.userShares - actualSharesBurned;
        vp.totalVaultShares -= actualSharesBurned;

        IERC20(tokenA).safeTransfer(msg.sender, amountA);
        IERC20(tokenB).safeTransfer(msg.sender, amountB);

        emit Withdrawn(pairId, msg.sender, amountA, amountB, actualSharesBurned);
    }

    /// @dev Pulled out of withdraw() to reduce stack depth. Computes the
    ///      percent-of-pool to remove, calls removeLiquidity, and calculates
    ///      the actual shares burned from the LP delta. Returns amounts in
    ///      the caller's original tokenA/tokenB order.
    function _removeLiquidityForShares(
        VaultPair storage vp,
        bytes32 pairId,
        WithdrawParams memory wp
    ) internal returns (uint256 amountA, uint256 amountB, uint256 actualSharesBurned) {
        uint256 lpBefore = poolLpShares(pairId);
        require(lpBefore > 0, "Vault: nothing deposited");

        uint256 pctOfPool = (wp.sharesToBurn * 100) / vp.totalVaultShares;
        require(pctOfPool > 0, "Vault: amount too small to withdraw (rounds to 0%)");
        if (pctOfPool > 100) pctOfPool = 100;

        (uint256 minA, uint256 minB) = wp.callerTokenA == vp.tokenA
            ? (wp.minAmountA, wp.minAmountB)
            : (wp.minAmountB, wp.minAmountA);

        (amountA, amountB) = pool.removeLiquidity(vp.tokenA, vp.tokenB, pctOfPool, minA, minB, wp.deadline);

        uint256 lpAfter = poolLpShares(pairId);
        uint256 lpBurned = lpBefore - lpAfter;

        // Burn the ACTUAL share-equivalent of the LP removed (can be
        // slightly less than sharesToBurn due to 1%-granularity rounding),
        // so vault-internal accounting always stays exact.
        actualSharesBurned = (lpBurned * vp.totalVaultShares) / lpBefore;
        if (actualSharesBurned > wp.userShares) actualSharesBurned = wp.userShares;

        // Re-orient amounts to the caller's original token argument order
        if (wp.callerTokenA != vp.tokenA) (amountA, amountB) = (amountB, amountA);
    }

    // ─────────────────────────────────────────────────────────────────
    // Harvest — claims Pool swap fees accrued to the vault, skims a
    // performance fee to treasury, balances the remainder to the pool's
    // current ratio via a swap, and re-adds it as liquidity. Anyone can
    // call this (permissionless keeper-style); it only ever benefits
    // existing depositors.
    // ─────────────────────────────────────────────────────────────────
    function harvest(address tokenA, address tokenB, uint256 minLpOut, uint256 deadline)
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 lpMinted)
    {
        bytes32 pairId = getVaultPairId(tokenA, tokenB);
        VaultPair storage vp = vaultPairs[pairId];
        require(vp.exists, "Vault: pair not registered");
        require(vp.totalVaultShares > 0, "Vault: nothing deposited");

        (uint256 feeA, uint256 feeB) = pool.claimFees(vp.tokenA, vp.tokenB);
        require(feeA > 0 || feeB > 0, "Vault: nothing to harvest");

        // Performance fee comes out of harvested yield only, before any
        // compounding — principal is never touched.
        uint256 perfFeeA = (feeA * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 perfFeeB = (feeB * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
        if (perfFeeA > 0) IERC20(vp.tokenA).safeTransfer(treasury, perfFeeA);
        if (perfFeeB > 0) IERC20(vp.tokenB).safeTransfer(treasury, perfFeeB);
        feeA -= perfFeeA;
        feeB -= perfFeeB;

        uint256 lpBefore = poolLpShares(pairId);

        // Rebalance via internal helper to avoid stack-too-deep in this frame.
        (feeA, feeB) = _rebalanceAndAdd(vp, feeA, feeB, deadline);

        uint256 lpAfter = poolLpShares(pairId);
        lpMinted = lpAfter - lpBefore;
        require(lpMinted >= minLpOut, "Vault: harvest slippage exceeded");

        // totalVaultShares is intentionally UNCHANGED — this is the entire
        // auto-compound mechanism. Existing shares now represent more LP.
        emit Harvested(pairId, msg.sender, feeA, feeB, lpMinted);
    }

    /// @dev Shell: reads reserves, delegates swap to _swapToRatio, then adds liquidity.
    function _rebalanceAndAdd(
        VaultPair storage vp,
        uint256 feeA,
        uint256 feeB,
        uint256 deadline
    ) internal returns (uint256 outFeeA, uint256 outFeeB) {
        bytes32 poolPairId = pool.getPairId(vp.tokenA, vp.tokenB);
        (, , uint256 reserveA, uint256 reserveB, , ) = pool.getPairInfo(poolPairId);

        (feeA, feeB) = _swapToRatio(vp, feeA, feeB, reserveA, reserveB, deadline);

        if (feeA > 0 && feeB > 0) {
            IERC20(vp.tokenA).safeApprove(address(pool), feeA);
            IERC20(vp.tokenB).safeApprove(address(pool), feeB);
            pool.addLiquidity(vp.tokenA, vp.tokenB, feeA, feeB, deadline);
        }

        outFeeA = feeA;
        outFeeB = feeB;
    }

    /// @dev Decides which branch to swap and delegates to the appropriate helper.
    function _swapToRatio(
        VaultPair storage vp,
        uint256 feeA,
        uint256 feeB,
        uint256 reserveA,
        uint256 reserveB,
        uint256 deadline
    ) internal returns (uint256, uint256) {
        if (reserveA == 0 || reserveB == 0 || feeA == 0 || feeB == 0) {
            return (feeA, feeB);
        }
        uint256 idealB = (feeA * reserveB) / reserveA;
        if (idealB < feeB) {
            return _swapBtoA(vp, feeA, feeB, idealB, deadline);
        } else if (idealB > feeB) {
            return _swapAtoB(vp, feeA, feeB, reserveA, reserveB, deadline);
        }
        return (feeA, feeB);
    }

    /// @dev Branch: excess tokenB — swap some B -> A.
    function _swapBtoA(
        VaultPair storage vp,
        uint256 feeA,
        uint256 feeB,
        uint256 idealB,
        uint256 deadline
    ) internal returns (uint256, uint256) {
        uint256 swapAmt = (feeB - idealB) / 2;
        if (swapAmt > 0) {
            IERC20(vp.tokenB).safeApprove(address(pool), swapAmt);
            feeA += pool.executeSwap(vp.tokenB, vp.tokenA, swapAmt, 0, deadline);
            feeB -= swapAmt;
        }
        return (feeA, feeB);
    }

    /// @dev Branch: excess tokenA — swap some A -> B.
    function _swapAtoB(
        VaultPair storage vp,
        uint256 feeA,
        uint256 feeB,
        uint256 reserveA,
        uint256 reserveB,
        uint256 deadline
    ) internal returns (uint256, uint256) {
        uint256 idealA = (feeB * reserveA) / reserveB;
        uint256 swapAmt = (feeA > idealA ? feeA - idealA : 0) / 2;
        if (swapAmt > 0) {
            IERC20(vp.tokenA).safeApprove(address(pool), swapAmt);
            feeB += pool.executeSwap(vp.tokenA, vp.tokenB, swapAmt, 0, deadline);
            feeA -= swapAmt;
        }
        return (feeA, feeB);
    }

    // ─────────────────────────────────────────────────────────────────
    // Views for the frontend
    // ─────────────────────────────────────────────────────────────────
    function getVaultPosition(address user, address tokenA, address tokenB)
        external
        view
        returns (
            uint256 shares,
            uint256 totalShares,
            uint256 sharePctBps, // 10000 = 100%
            uint256 userLp,
            uint256 valueA,
            uint256 valueB
        )
    {
        bytes32 pairId = getVaultPairId(tokenA, tokenB);
        VaultPair storage vp = vaultPairs[pairId];
        shares = userVaultShares[pairId][user];
        totalShares = vp.totalVaultShares;
        sharePctBps = totalShares > 0 ? (shares * BPS_DENOMINATOR) / totalShares : 0;

        uint256 lpOwned = poolLpShares(pairId);
        userLp = totalShares > 0 ? (shares * lpOwned) / totalShares : 0;

        bytes32 poolPairId = pool.getPairId(vp.tokenA, vp.tokenB);
        (, , uint256 reserveA, uint256 reserveB, uint256 poolTotalShares, ) = pool.getPairInfo(poolPairId);
        valueA = poolTotalShares > 0 ? (userLp * reserveA) / poolTotalShares : 0;
        valueB = poolTotalShares > 0 ? (userLp * reserveB) / poolTotalShares : 0;
    }
}
