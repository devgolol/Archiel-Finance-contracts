// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║         ARCHIEL FINANCE — RegarSwap Liquidity Pool V1                   ║
 * ║         Replaces: 0xFe209B46c3BAA177bCcba0F719368A63ee6f3Cb2           ║
 * ╠══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  WHAT THIS FIXES                                                         ║
 * ║  The old contract had depositLiquidity() and executeSwap() but           ║
 * ║  withdrawLiquidity() always reverted — trapping user funds forever.     ║
 * ║  This contract gives LPs full control to withdraw their liquidity.      ║
 * ║                                                                          ║
 * ║  HOW IT WORKS                                                            ║
 * ║  ─────────────────────────────────────────────────────────────────────  ║
 * ║                                                                          ║
 * ║  1. LP provides TokenA + TokenB to a pair pool                          ║
 * ║  2. They receive LP shares proportional to their deposit                ║
 * ║  3. Swappers pay a 0.3% fee — split between LPs and protocol           ║
 * ║  4. LP withdraws anytime → gets back their share + accumulated fees    ║
 * ║  5. You (owner) earn protocol fees automatically                        ║
 * ║                                                                          ║
 * ║  LP SHARE FORMULA                                                        ║
 * ║    First deposit sets the ratio.                                         ║
 * ║    shares = min(amountA/reserveA, amountB/reserveB) × totalShares      ║
 * ║    On withdraw: receive = shares/totalShares × reserves                 ║
 * ║                                                                          ║
 * ║  FEE SPLIT (per swap)                                                    ║
 * ║    0.3% total swap fee                                                   ║
 * ║    → 0.25% to LP reward pool (distributed proportionally to LPs)       ║
 * ║    → 0.05% to owner protocol vault                                      ║
 * ║                                                                          ║
 * ║  SUPPORTED PAIRS (pre-configured, more can be added by owner)           ║
 * ║    REGAR/USDC  •  REGAR/EURC  •  USDC/ARCL  •  REGAR/ARCL             ║
 * ║    Any pair of any two ERC-20 tokens can be added                       ║
 * ║                                                                          ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 */

interface IERC20 {
    function balanceOf(address account)                             external view returns (uint256);
    function transfer(address to, uint256 amount)                   external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals()                                             external view returns (uint8);
}

contract ArchielLiquidityPool {

    // ─────────────────────────────────────────────────────────────────
    //  Reentrancy guard
    // ─────────────────────────────────────────────────────────────────
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status != 2, "Reentrant");
        _status = 2;
        _;
        _status = 1;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Fee config
    // ─────────────────────────────────────────────────────────────────
    uint256 public constant SWAP_FEE_BPS      = 30;   // 0.3% total swap fee
    uint256 public constant LP_FEE_SHARE_BPS  = 8333; // 83.33% of fee → LPs (= 0.25% of swap)
    uint256 public constant PRECISION         = 1e18;

    // ─────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────
    address public owner;

    struct Pair {
        address tokenA;
        address tokenB;
        uint256 reserveA;       // tokens held by contract for this pair
        uint256 reserveB;
        uint256 totalShares;    // total LP shares issued
        uint256 feeAccumA;      // accumulated LP fees in tokenA (claimable by LPs)
        uint256 feeAccumB;      // accumulated LP fees in tokenB
        bool    exists;
        string  name;           // e.g. "REGAR/USDC"
    }

    // pairId → Pair  (pairId = keccak256(sorted token addresses))
    mapping(bytes32 => Pair)    public pairs;
    bytes32[]                   public pairList;

    // pairId → user → LP shares
    mapping(bytes32 => mapping(address => uint256)) public lpShares;

    // pairId → user → fee snapshot at time of deposit (for fee accounting)
    mapping(bytes32 => mapping(address => uint256)) public feeSnapshotA;
    mapping(bytes32 => mapping(address => uint256)) public feeSnapshotB;

    // Protocol fee vault: tokenAddress → accumulated fees for owner
    mapping(address => uint256) public protocolFeeVault;

    // ─────────────────────────────────────────────────────────────────
    //  Futures counterparty reserve
    //  A SEPARATE pot of funds (NOT the swap-pair reserves above) that
    //  backs trader PnL for the ArchielFutures contract. Keeping this
    //  separate means a losing/winning trader never moves swap prices
    //  or touches LP principal in pairs[].
    // ─────────────────────────────────────────────────────────────────
    address public futuresContract;                       // only this address may call payout/receive below
    mapping(address => uint256) public futuresReserve;     // token → funds available to pay trader profits

    // ─────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────
    event PairAdded(bytes32 indexed pairId, address tokenA, address tokenB, string name);
    event LiquidityAdded(bytes32 indexed pairId, address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event LiquidityRemoved(bytes32 indexed pairId, address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event Swap(bytes32 indexed pairId, address indexed user, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, uint256 fee);
    event ProtocolFeesCollected(address indexed token, uint256 amount);
    event FeesClaimed(bytes32 indexed pairId, address indexed provider, uint256 feeA, uint256 feeB);
    event FuturesContractSet(address indexed futuresContract);
    event FuturesPoolFunded(address indexed funder, address indexed token, uint256 amount);
    event FuturesPoolWithdrawn(address indexed to, address indexed token, uint256 amount);
    event FuturesPayout(address indexed trader, address indexed token, uint256 amount);
    event FuturesRepayment(address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────────
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    modifier onlyFuturesContract() { require(msg.sender == futuresContract, "Not futures contract"); _; }

    // ─────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────

    function _pairId(address tA, address tB) internal pure returns (bytes32) {
        // Always sort so REGAR/USDC and USDC/REGAR give the same pairId
        (address a, address b) = tA < tB ? (tA, tB) : (tB, tA);
        return keccak256(abi.encodePacked(a, b));
    }

    function _getPair(address tA, address tB) internal view returns (bytes32 pid, Pair storage p) {
        pid = _pairId(tA, tB);
        p   = pairs[pid];
        require(p.exists, "Pair does not exist");
    }

    // Normalize pair amounts so tokenA in Pair always matches the sorted order
    function _sort(address tA, address tB, uint256 amtA, uint256 amtB)
        internal pure
        returns (address, address, uint256, uint256)
    {
        if (tA < tB) return (tA, tB, amtA, amtB);
        return (tB, tA, amtB, amtA);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Owner: pair management
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Add a new trading pair.
     *         Can be called for any two ERC-20 tokens.
     *
     * @param tokenA  First token address
     * @param tokenB  Second token address
     * @param name    Display name e.g. "REGAR/USDC"
     */
    function addPair(address tokenA, address tokenB, string calldata name)
        external onlyOwner
    {
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        require(tokenA != tokenB, "Same token");
        bytes32 pid = _pairId(tokenA, tokenB);
        require(!pairs[pid].exists, "Pair exists");

        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        pairs[pid] = Pair({
            tokenA:      a,
            tokenB:      b,
            reserveA:    0,
            reserveB:    0,
            totalShares: 0,
            feeAccumA:   0,
            feeAccumB:   0,
            exists:      true,
            name:        name
        });
        pairList.push(pid);
        emit PairAdded(pid, a, b, name);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero");
        owner = newOwner;
    }

    /**
     * @notice Collect accumulated protocol fees.
     */
    function collectProtocolFees(address token) external onlyOwner nonReentrant {
        uint256 amt = protocolFeeVault[token];
        require(amt > 0, "Nothing to collect");
        protocolFeeVault[token] = 0;
        IERC20(token).transfer(owner, amt);
        emit ProtocolFeesCollected(token, amt);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Futures counterparty pool
    //  Separate from the swap-pair reserves above. Only the registered
    //  ArchielFutures contract can pay traders from this pot or repay
    //  into it — it never touches pairs[] reserves or LP shares.
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Set (or replace) the ArchielFutures contract allowed to call
     *         payoutToTrader / receiveFromFutures. Owner only.
     */
    function setFuturesContract(address _futuresContract) external onlyOwner {
        require(_futuresContract != address(0), "Zero address");
        futuresContract = _futuresContract;
        emit FuturesContractSet(_futuresContract);
    }

    /**
     * @notice Fund the futures counterparty pool with a token. Anyone may
     *         contribute (e.g. the owner seeding it, or LPs opting in
     *         separately from their swap-pair liquidity).
     *         MUST approve this contract for `amount` first.
     */
    function fundFuturesPool(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        futuresReserve[token] += amount;
        emit FuturesPoolFunded(msg.sender, token, amount);
    }

    /**
     * @notice Emergency owner withdrawal from the futures pool (e.g. to
     *         retire the futures product or rebalance). Does not affect
     *         swap-pair reserves or LP funds in any way.
     */
    function withdrawFuturesPool(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        require(amount <= futuresReserve[token], "Exceeds futures reserve");
        futuresReserve[token] -= amount;
        require(IERC20(token).transfer(to, amount), "Transfer failed");
        emit FuturesPoolWithdrawn(to, token, amount);
    }

    /**
     * @notice Pay a winning trader's profit out of the futures pool.
     *         Callable ONLY by the registered ArchielFutures contract.
     */
    function payoutToTrader(address token, address trader, uint256 amount)
        external onlyFuturesContract nonReentrant
    {
        require(amount <= futuresReserve[token], "Insufficient futures reserve");
        futuresReserve[token] -= amount;
        require(IERC20(token).transfer(trader, amount), "Transfer failed");
        emit FuturesPayout(trader, token, amount);
    }

    /**
     * @notice Deposit a losing trader's forfeited margin/loss back into the
     *         futures pool. Callable ONLY by the registered ArchielFutures
     *         contract, which must approve/hold the tokens being repaid.
     */
    function receiveFromFutures(address token, uint256 amount) external onlyFuturesContract nonReentrant {
        require(amount > 0, "Zero amount");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        futuresReserve[token] += amount;
        emit FuturesRepayment(token, amount);
    }

    // ─────────────────────────────────────────────────────────────────
    //  LP: add liquidity  (REPLACES old depositLiquidity)
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Add liquidity to a pair pool and receive LP shares.
     *         You can withdraw your share anytime with removeLiquidity().
     *
     *         MUST approve this contract for both tokens before calling.
     *
     * @param tokenA   First token of the pair
     * @param tokenB   Second token of the pair
     * @param amountA  Amount of tokenA to deposit
     * @param amountB  Amount of tokenB to deposit
     *                 (ignored on first deposit — sets the price ratio)
     *                 (on subsequent deposits, must match current ratio or excess is refunded)
     *
     * @return shares  LP shares minted to caller
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) external nonReentrant returns (uint256 shares) {
        require(amountA > 0 && amountB > 0, "Zero amount");

        (address sA, address sB, uint256 sAmtA, uint256 sAmtB) = _sort(tokenA, tokenB, amountA, amountB);
        bytes32 pid = _pairId(sA, sB);

        uint256 actualA;
        uint256 actualB;
        (shares, actualA, actualB) = _calcLiquidityShares(pid, sAmtA, sAmtB);
        require(shares > 0, "Zero shares");

        // Pull tokens from LP
        require(IERC20(sA).transferFrom(msg.sender, address(this), actualA), "TransferA failed");
        require(IERC20(sB).transferFrom(msg.sender, address(this), actualB), "TransferB failed");

        _recordLiquidityDeposit(pid, actualA, actualB, shares);

        emit LiquidityAdded(pid, msg.sender, actualA, actualB, shares);
    }

    /// @dev Pure share-math for addLiquidity(), split out to avoid stack-too-deep.
    function _calcLiquidityShares(bytes32 pid, uint256 sAmtA, uint256 sAmtB)
        internal view returns (uint256 shares, uint256 actualA, uint256 actualB)
    {
        Pair storage p = pairs[pid];
        require(p.exists, "Pair does not exist");

        if (p.totalShares == 0) {
            // First deposit: geometric mean sets initial share price
            shares  = _sqrt(sAmtA * sAmtB);
            actualA = sAmtA;
            actualB = sAmtB;
        } else {
            // Subsequent deposit: enforce existing ratio, refund excess
            uint256 bOptimal = (sAmtA * p.reserveB) / p.reserveA;
            if (bOptimal <= sAmtB) {
                actualA = sAmtA;
                actualB = bOptimal;
            } else {
                actualA = (sAmtB * p.reserveA) / p.reserveB;
                actualB = sAmtB;
            }
            shares = (actualA * p.totalShares) / p.reserveA;
        }
    }

    /// @dev State updates for addLiquidity(), split out to avoid stack-too-deep.
    function _recordLiquidityDeposit(bytes32 pid, uint256 actualA, uint256 actualB, uint256 shares) internal {
        Pair storage p = pairs[pid];

        // Record fee snapshots for this LP (so they only earn fees from now on)
        if (lpShares[pid][msg.sender] == 0) {
            feeSnapshotA[pid][msg.sender] = p.feeAccumA;
            feeSnapshotB[pid][msg.sender] = p.feeAccumB;
        }

        p.reserveA    += actualA;
        p.reserveB    += actualB;
        p.totalShares += shares;
        lpShares[pid][msg.sender] += shares;
    }

    // ─────────────────────────────────────────────────────────────────
    //  LP: remove liquidity  (REPLACES broken withdrawLiquidity)
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw your liquidity. Returns your proportional share of
     *         the pool reserves PLUS your accumulated swap fees.
     *
     *         This function ALWAYS works — it is the core fix over the old contract.
     *
     * @param tokenA      First token of the pair
     * @param tokenB      Second token of the pair
     * @param sharePct    Percentage of YOUR shares to withdraw (1–100)
     *
     * @return amountA    tokenA returned to caller
     * @return amountB    tokenB returned to caller
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 sharePct
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        require(sharePct >= 1 && sharePct <= 100, "Pct must be 1-100");

        (address sA, address sB,,) = _sort(tokenA, tokenB, 0, 0);
        bytes32 pid = _pairId(sA, sB);

        uint256 sharesToBurn;
        (amountA, amountB, sharesToBurn) = _calcWithdrawAmounts(pid, sharePct);

        require(IERC20(sA).transfer(msg.sender, amountA), "TransferA failed");
        require(IERC20(sB).transfer(msg.sender, amountB), "TransferB failed");

        emit LiquidityRemoved(pid, msg.sender, amountA, amountB, sharesToBurn);
    }

    /// @dev Withdraw math + state update for removeLiquidity(), split out to
    ///      avoid stack-too-deep. Returns principal+fees combined per token.
    function _calcWithdrawAmounts(bytes32 pid, uint256 sharePct)
        internal returns (uint256 amountA, uint256 amountB, uint256 sharesToBurn)
    {
        Pair storage p = pairs[pid];
        require(p.exists, "Pair does not exist");

        uint256 userShares = lpShares[pid][msg.sender];
        require(userShares > 0, "No liquidity to withdraw");

        sharesToBurn = (userShares * sharePct) / 100;
        require(sharesToBurn > 0, "Zero shares");

        amountA = (sharesToBurn * p.reserveA) / p.totalShares;
        amountB = (sharesToBurn * p.reserveB) / p.totalShares;

        uint256 feeA;
        uint256 feeB;
        (feeA, feeB) = _calcWithdrawFees(pid, p, userShares, amountA, amountB);

        p.reserveA    -= (amountA + feeA);
        p.reserveB    -= (amountB + feeB);
        p.totalShares -= sharesToBurn;
        lpShares[pid][msg.sender] -= sharesToBurn;

        if (lpShares[pid][msg.sender] == 0) {
            feeSnapshotA[pid][msg.sender] = 0;
            feeSnapshotB[pid][msg.sender] = 0;
        } else {
            feeSnapshotA[pid][msg.sender] = p.feeAccumA;
            feeSnapshotB[pid][msg.sender] = p.feeAccumB;
        }

        amountA += feeA;
        amountB += feeB;
    }

    /// @dev Pending-fee math for removeLiquidity(), capped to available reserves.
    function _calcWithdrawFees(bytes32 pid, Pair storage p, uint256 userShares, uint256 amountA, uint256 amountB)
        internal view returns (uint256 feeA, uint256 feeB)
    {
        feeA = ((p.feeAccumA - feeSnapshotA[pid][msg.sender]) * userShares) / PRECISION;
        feeB = ((p.feeAccumB - feeSnapshotB[pid][msg.sender]) * userShares) / PRECISION;

        feeA = feeA > p.reserveA - amountA ? p.reserveA - amountA : feeA;
        feeB = feeB > p.reserveB - amountB ? p.reserveB - amountB : feeB;
    }

    /**
     * @notice Claim accumulated LP fees WITHOUT withdrawing your deposited
     *         liquidity. Shares and principal stay exactly as they are —
     *         only the accrued 0.25% swap-fee share is paid out.
     *
     * @param tokenA  First token of the pair
     * @param tokenB  Second token of the pair
     *
     * @return feeA   tokenA fees sent to caller
     * @return feeB   tokenB fees sent to caller
     */
    function claimFees(address tokenA, address tokenB)
        external nonReentrant returns (uint256 feeA, uint256 feeB)
    {
        (address sA, address sB,,) = _sort(tokenA, tokenB, 0, 0);
        bytes32 pid = _pairId(sA, sB);
        Pair storage p = pairs[pid];
        require(p.exists, "Pair does not exist");

        uint256 userShares = lpShares[pid][msg.sender];
        require(userShares > 0, "No liquidity in pool");

        feeA = ((p.feeAccumA - feeSnapshotA[pid][msg.sender]) * userShares) / PRECISION;
        feeB = ((p.feeAccumB - feeSnapshotB[pid][msg.sender]) * userShares) / PRECISION;
        require(feeA > 0 || feeB > 0, "Nothing to claim");

        // Fees live inside the pool reserves (added there at swap time),
        // so paying them out reduces reserves — but NOT shares or principal.
        feeA = feeA > p.reserveA ? p.reserveA : feeA;
        feeB = feeB > p.reserveB ? p.reserveB : feeB;

        p.reserveA -= feeA;
        p.reserveB -= feeB;

        feeSnapshotA[pid][msg.sender] = p.feeAccumA;
        feeSnapshotB[pid][msg.sender] = p.feeAccumB;

        if (feeA > 0) require(IERC20(sA).transfer(msg.sender, feeA), "TransferA failed");
        if (feeB > 0) require(IERC20(sB).transfer(msg.sender, feeB), "TransferB failed");

        emit FeesClaimed(pid, msg.sender, feeA, feeB);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Swap  (keeps executeSwap signature for frontend compatibility)
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a token swap. Charges 0.3% fee split between LPs + protocol.
     *
     *         MUST approve this contract for amountIn of tokenIn before calling.
     *
     * @param tokenIn    Token user is selling
     * @param tokenOut   Token user is buying
     * @param amountIn   Amount of tokenIn (raw units)
     * @param minOut     Minimum amountOut accepted (slippage protection)
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "Zero input");
        require(tokenIn != tokenOut, "Same token");

        bytes32 pid = _pairId(tokenIn, tokenOut);
        Pair storage p = pairs[pid];
        require(p.exists, "Pair does not exist");
        require(p.reserveA > 0 && p.reserveB > 0, "Empty pool");

        // Pull tokenIn from user
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "Transfer failed");

        uint256 totalFee;
        (amountOut, totalFee) = _settleSwap(pid, tokenIn, amountIn, minOut);

        require(IERC20(tokenOut).transfer(msg.sender, amountOut), "Output transfer failed");

        emit Swap(pid, msg.sender, tokenIn, amountIn, tokenOut, amountOut, totalFee);
    }

    /**
     * @dev Pure-ish swap math + state update, split out of executeSwap() to
     *      keep each function's stack depth within the EVM's 16-slot limit.
     *      Returns (amountOut, totalFee) so the caller can still emit an
     *      accurate Swap event.
     */
    function _settleSwap(bytes32 pid, address tokenIn, uint256 amountIn, uint256 minOut)
        internal returns (uint256 amountOut, uint256 totalFee)
    {
        Pair storage p = pairs[pid];
        bool inIsA = tokenIn == p.tokenA;

        uint256 reserveIn  = inIsA ? p.reserveA : p.reserveB;
        uint256 reserveOut = inIsA ? p.reserveB : p.reserveA;

        uint256 lpFee;
        uint256 amountInNet;
        (totalFee, lpFee, amountInNet) = _splitFee(amountIn);

        // Constant product formula: x * y = k
        amountOut = (reserveOut * amountInNet) / (reserveIn + amountInNet);
        require(amountOut >= minOut, "Slippage: output below minimum");
        require(amountOut < reserveOut, "Insufficient liquidity");

        _applySwapReserves(p, inIsA, amountIn, amountOut, lpFee);
        protocolFeeVault[tokenIn] += (totalFee - lpFee);
    }

    /// @dev Splits the 0.3% swap fee into LP share / protocol share.
    function _splitFee(uint256 amountIn)
        internal pure returns (uint256 totalFee, uint256 lpFee, uint256 amountInNet)
    {
        totalFee    = (amountIn * SWAP_FEE_BPS) / 10_000;
        lpFee       = (totalFee * LP_FEE_SHARE_BPS) / 10_000;  // 0.25% to LPs
        amountInNet = amountIn - totalFee;
    }

    /// @dev Applies the post-swap reserve and fee-accumulator updates.
    function _applySwapReserves(Pair storage p, bool inIsA, uint256 amountIn, uint256 amountOut, uint256 lpFee) internal {
        if (inIsA) {
            p.reserveA += amountIn;
            p.reserveB -= amountOut;
            if (p.totalShares > 0) p.feeAccumA += (lpFee * PRECISION) / p.totalShares;
        } else {
            p.reserveB += amountIn;
            p.reserveA -= amountOut;
            if (p.totalShares > 0) p.feeAccumB += (lpFee * PRECISION) / p.totalShares;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  Backwards compatibility: old depositLiquidity signature
    //  (so existing frontend calls don't break during transition)
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Legacy entrypoint kept for frontend backwards compatibility.
     *         Deposits a single token into ANY pair that contains it.
     *         Prefer addLiquidity() for new integrations.
     * @dev    Loops through pairs to find one containing _token.
     */
    function depositLiquidity(address _token, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Zero amount");
        require(IERC20(_token).transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        // Find first pair containing this token and credit reserve
        for (uint256 i = 0; i < pairList.length; i++) {
            Pair storage p = pairs[pairList[i]];
            if (p.tokenA == _token) { p.reserveA += _amount; return; }
            if (p.tokenB == _token) { p.reserveB += _amount; return; }
        }
        revert("No pair found for this token");
    }

    // ─────────────────────────────────────────────────────────────────
    //  View functions
    // ─────────────────────────────────────────────────────────────────

    function getPairId(address tokenA, address tokenB) external pure returns (bytes32) {
        return _pairId(tokenA, tokenB);
    }

    function getAllPairs() external view returns (bytes32[] memory) {
        return pairList;
    }

    /**
     * @notice Get a user's LP position details including pending fees.
     */
    function getLpPosition(address user, address tokenA, address tokenB)
        external view
        returns (
            uint256 shares,
            uint256 totalShares,
            uint256 poolSharePct,   // user's % of pool × 100 (e.g. 2500 = 25%)
            uint256 valueA,         // tokenA the user can withdraw right now
            uint256 valueB,         // tokenB the user can withdraw right now
            uint256 pendingFeeA,
            uint256 pendingFeeB
        )
    {
        bytes32 pid = _pairId(tokenA, tokenB);

        shares      = lpShares[pid][user];
        totalShares = pairs[pid].totalShares;

        if (shares == 0 || totalShares == 0) {
            return (0, 0, 0, 0, 0, 0, 0);
        }

        (poolSharePct, valueA, valueB) = _lpPositionValues(pid, shares, totalShares);
        (pendingFeeA, pendingFeeB) = _lpPositionFees(pid, user, shares);
    }

    // Split out of getLpPosition to keep stack depth within EVM limits.
    function _lpPositionValues(bytes32 pid, uint256 shares, uint256 totalShares)
        internal view
        returns (uint256 poolSharePct, uint256 valueA, uint256 valueB)
    {
        Pair storage p = pairs[pid];
        poolSharePct = (shares * 10_000) / totalShares;
        valueA       = (shares * p.reserveA) / totalShares;
        valueB       = (shares * p.reserveB) / totalShares;
    }

    // Split out of getLpPosition to keep stack depth within EVM limits.
    function _lpPositionFees(bytes32 pid, address user, uint256 shares)
        internal view
        returns (uint256 pendingFeeA, uint256 pendingFeeB)
    {
        Pair storage p = pairs[pid];
        pendingFeeA = ((p.feeAccumA - feeSnapshotA[pid][user]) * shares) / PRECISION;
        pendingFeeB = ((p.feeAccumB - feeSnapshotB[pid][user]) * shares) / PRECISION;
    }

    /**
     * @notice Get swap quote — how much tokenOut for a given amountIn.
     */
    function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view
        returns (uint256 amountOut, uint256 fee)
    {
        (address sA, address sB,,) = _sort(tokenIn, tokenOut, 0, 0);
        bytes32 pid = _pairId(sA, sB);
        Pair storage p = pairs[pid];
        if (!p.exists || p.reserveA == 0 || p.reserveB == 0) return (0, 0);

        bool inIsA    = tokenIn == sA;
        uint256 resIn = inIsA ? p.reserveA : p.reserveB;
        uint256 resOut = inIsA ? p.reserveB : p.reserveA;

        fee       = (amountIn * SWAP_FEE_BPS) / 10_000;
        uint256 netIn = amountIn - fee;
        amountOut = (resOut * netIn) / (resIn + netIn);
    }

    function getPairInfo(bytes32 pairId)
        external view
        returns (
            address tokenA,
            address tokenB,
            uint256 reserveA,
            uint256 reserveB,
            uint256 totalShares,
            string memory name
        )
    {
        Pair storage p = pairs[pairId];
        require(p.exists, "Pair does not exist");
        return (p.tokenA, p.tokenB, p.reserveA, p.reserveB, p.totalShares, p.name);
    }
}
