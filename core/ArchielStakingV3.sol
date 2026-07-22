// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║           ARCHIEL FINANCE — Universal Staking Hub V3                    ║
 * ║           Self-Sustaining Rewards + Protocol Fee Income                 ║
 * ╠══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  HOW REWARDS WORK (3 sources, all automatic)                            ║
 * ║  ──────────────────────────────────────────────────────────────────     ║
 * ║                                                                          ║
 * ║  SOURCE 1 — STAKE FEE (you earn every time someone stakes)              ║
 * ║    When a user stakes 1000 REGAR:                                        ║
 * ║    • stakeFeeBps = 10 (1%)                                              ║
 * ║    • 10 REGAR goes to ownerFeeVault  ← YOUR income                      ║
 * ║    • 990 REGAR is the effective staked amount                            ║
 * ║                                                                          ║
 * ║  SOURCE 2 — UNSTAKE FEE (you earn every time someone unstakes)          ║
 * ║    When a user unstakes:                                                 ║
 * ║    • unstakeFeeBps = 50 (0.5%)                                           ║
 * ║    • Half goes to ownerFeeVault  ← YOUR income                          ║
 * ║    • Half goes to rewardPool     ← replenishes rewards for other stakers ║
 * ║                                                                          ║
 * ║  SOURCE 3 — INITIAL SEED (optional one-time deposit)                    ║
 * ║    You or a partner calls fundRewardPool() once to bootstrap.            ║
 * ║    Fees then keep it alive indefinitely.                                 ║
 * ║                                                                          ║
 * ║  RESULT                                                                  ║
 * ║    • The more users stake/unstake, the bigger the reward pool grows     ║
 * ║    • You earn protocol fees automatically into ownerFeeVault             ║
 * ║    • You withdraw your fees anytime with collectFees()                   ║
 * ║    • Partners fund their own pools; you still earn fees on their volume  ║
 * ║                                                                          ║
 * ║  EXAMPLE NUMBERS                                                         ║
 * ║    100 users each stake 1000 REGAR (1% stake fee):                      ║
 * ║    → You instantly receive: 1000 REGAR in your fee vault                ║
 * ║    → Reward pool topped up from unstake fees over time                  ║
 * ║    → You never need to manually refill rewards                           ║
 * ║                                                                          ║
 * ╠══════════════════════════════════════════════════════════════════════════╣
 * ║  PARTNER INTEGRATION                                                     ║
 * ║    Partner calls addPool() → fundRewardPool() → users start staking     ║
 * ║    You earn fees on ALL partner pool volume automatically               ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 */

interface IERC20 {
    function balanceOf(address account)                             external view returns (uint256);
    function transfer(address to, uint256 amount)                   external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals()                                             external view returns (uint8);
    function symbol()                                               external view returns (string memory);
}

contract ArchielStakingV3 {

    // ─────────────────────────────────────────────────────────────────
    //  Reentrancy guard
    // ─────────────────────────────────────────────────────────────────
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────
    uint256 public constant MAX_FEE_BPS     = 1000;  // 10% max fee (safety cap)
    uint256 public constant MAX_APR_BPS     = 50000; // 500% max APR

    // What fraction of the unstake fee goes to reward pool vs owner vault
    // e.g. 5000 = 50% of unstake fee → reward pool, 50% → owner
    uint256 public unstakeFeeToRewardPoolBps = 5000;

    // ─────────────────────────────────────────────────────────────────
    //  Global fee config (applies to all pools unless overridden)
    // ─────────────────────────────────────────────────────────────────
    uint256 public defaultStakeFeeBps   = 100;  // 1% default stake fee
    uint256 public defaultUnstakeFeeBps = 50;   // 0.5% default unstake fee

    // ─────────────────────────────────────────────────────────────────
    //  Owner & fee accounting
    // ─────────────────────────────────────────────────────────────────
    address public owner;

    // token address → accumulated fees available for owner to collect
    mapping(address => uint256) public ownerFeeVault;

    // ─────────────────────────────────────────────────────────────────
    //  Pool storage
    // ─────────────────────────────────────────────────────────────────
    struct Pool {
        address stakeToken;
        address rewardToken;
        uint256 aprBps;
        uint256 rewardPool;      // tokens available to pay as rewards
        uint256 totalStaked;     // sum of all staked principal (after fees)
        uint256 totalFeesEarned; // lifetime fees earned from this pool (for stats)
        bool    exists;
        bool    paused;
        address partner;
        string  name;
        string  logoUrl;
        // Per-pool fee overrides (0 = use global default)
        uint256 stakeFeeBps;
        uint256 unstakeFeeBps;
    }

    struct Position {
        uint256 stakedAmount;    // net amount after stake fee deducted
        uint256 stakeStartTime;
        uint256 rewardDebt;
    }

    mapping(address => Pool)                              public pools;
    address[]                                             public poolList;
    mapping(address => mapping(address => Position))      public positions;

    // ─────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────
    event PoolAdded(address indexed stakeToken, address indexed rewardToken, uint256 aprBps, address partner);
    event PoolUpdated(address indexed stakeToken, uint256 newAprBps);
    event PoolPaused(address indexed stakeToken, bool paused);
    event RewardsFunded(address indexed stakeToken, address indexed funder, uint256 amount);
    event Staked(address indexed user, address indexed stakeToken, uint256 grossAmount, uint256 netAmount, uint256 fee);
    event Claimed(address indexed user, address indexed stakeToken, uint256 rewardAmount);
    event Unstaked(address indexed user, address indexed stakeToken, uint256 principal, uint256 rewards, uint256 fee);
    event EmergencyExit(address indexed user, address indexed stakeToken, uint256 principal);
    event FeesCollected(address indexed token, address indexed to, uint256 amount);
    event RewardSeedWithdrawn(address indexed stakeToken, uint256 amount);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ─────────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier poolExists(address t) {
        require(pools[t].exists, "Pool does not exist");
        _;
    }

    modifier poolActive(address t) {
        require(pools[t].exists, "Pool does not exist");
        require(!pools[t].paused, "Pool is paused");
        _;
    }

    modifier onlyOwnerOrPartner(address t) {
        Pool storage p = pools[t];
        require(
            msg.sender == owner || (p.partner != address(0) && msg.sender == p.partner),
            "Not authorized"
        );
        _;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────
    constructor() {
        owner   = msg.sender;
        _status = _NOT_ENTERED;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────
    function _getStakeFeeBps(address stakeToken) internal view returns (uint256) {
        uint256 custom = pools[stakeToken].stakeFeeBps;
        return custom > 0 ? custom : defaultStakeFeeBps;
    }

    function _getUnstakeFeeBps(address stakeToken) internal view returns (uint256) {
        uint256 custom = pools[stakeToken].unstakeFeeBps;
        return custom > 0 ? custom : defaultUnstakeFeeBps;
    }

    function _pendingRewards(address user, address stakeToken)
        internal view returns (uint256)
    {
        Position storage pos = positions[user][stakeToken];
        if (pos.stakedAmount == 0 || pos.stakeStartTime == 0) return 0;
        uint256 elapsed = block.timestamp - pos.stakeStartTime;
        return (pos.stakedAmount * pools[stakeToken].aprBps * elapsed) / (10_000 * 365 days);
    }

    function _checkpoint(address user, address stakeToken) internal {
        Position storage pos = positions[user][stakeToken];
        if (pos.stakedAmount > 0 && pos.stakeStartTime > 0) {
            pos.rewardDebt    += _pendingRewards(user, stakeToken);
            pos.stakeStartTime = block.timestamp;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  Owner: pool management
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Add any ERC-20 token as a staking pool.
     * @param stakeToken    Token users stake
     * @param rewardToken   Token paid as rewards (can be same or different)
     * @param aprBps        APR in basis points (5000 = 50%)
     * @param partner       Partner wallet, or address(0) for ARCHIEL-owned pool
     * @param name          Display name e.g. "REGAR", "XYZ"
     * @param logoUrl       Logo URL for frontend
     * @param stakeFeeBps   Per-pool stake fee override (0 = use global default)
     * @param unstakeFeeBps Per-pool unstake fee override (0 = use global default)
     */
    function addPool(
        address stakeToken,
        address rewardToken,
        uint256 aprBps,
        address partner,
        string  calldata name,
        string  calldata logoUrl,
        uint256 stakeFeeBps,
        uint256 unstakeFeeBps
    ) external onlyOwner {
        require(stakeToken  != address(0), "Zero stakeToken");
        require(rewardToken != address(0), "Zero rewardToken");
        require(!pools[stakeToken].exists,  "Pool exists");
        require(aprBps > 0 && aprBps <= MAX_APR_BPS, "APR out of range");
        require(stakeFeeBps   <= MAX_FEE_BPS, "Stake fee too high");
        require(unstakeFeeBps <= MAX_FEE_BPS, "Unstake fee too high");

        pools[stakeToken] = Pool({
            stakeToken:      stakeToken,
            rewardToken:     rewardToken,
            aprBps:          aprBps,
            rewardPool:      0,
            totalStaked:     0,
            totalFeesEarned: 0,
            exists:          true,
            paused:          false,
            partner:         partner,
            name:            name,
            logoUrl:         logoUrl,
            stakeFeeBps:     stakeFeeBps,
            unstakeFeeBps:   unstakeFeeBps
        });
        poolList.push(stakeToken);
        emit PoolAdded(stakeToken, rewardToken, aprBps, partner);
    }

    function setApr(address stakeToken, uint256 newAprBps)
        external onlyOwnerOrPartner(stakeToken) poolExists(stakeToken)
    {
        require(newAprBps > 0 && newAprBps <= MAX_APR_BPS, "APR out of range");
        pools[stakeToken].aprBps = newAprBps;
        emit PoolUpdated(stakeToken, newAprBps);
    }

    function setPoolFees(address stakeToken, uint256 stakeFeeBps, uint256 unstakeFeeBps)
        external onlyOwner poolExists(stakeToken)
    {
        require(stakeFeeBps   <= MAX_FEE_BPS, "Too high");
        require(unstakeFeeBps <= MAX_FEE_BPS, "Too high");
        pools[stakeToken].stakeFeeBps   = stakeFeeBps;
        pools[stakeToken].unstakeFeeBps = unstakeFeeBps;
    }

    function setDefaultFees(uint256 stakeFeeBps, uint256 unstakeFeeBps) external onlyOwner {
        require(stakeFeeBps   <= MAX_FEE_BPS, "Too high");
        require(unstakeFeeBps <= MAX_FEE_BPS, "Too high");
        defaultStakeFeeBps   = stakeFeeBps;
        defaultUnstakeFeeBps = unstakeFeeBps;
    }

    function setUnstakeFeeToRewardPoolBps(uint256 bps) external onlyOwner {
        require(bps <= 10000, "Exceeds 100%");
        unstakeFeeToRewardPoolBps = bps;
    }

    function setPaused(address stakeToken, bool paused)
        external onlyOwner poolExists(stakeToken)
    {
        pools[stakeToken].paused = paused;
        emit PoolPaused(stakeToken, paused);
    }

    function setPartner(address stakeToken, address newPartner) external onlyOwner poolExists(stakeToken) {
        pools[stakeToken].partner = newPartner;
    }

    function setLogoUrl(address stakeToken, string calldata logoUrl)
        external onlyOwnerOrPartner(stakeToken) poolExists(stakeToken)
    {
        pools[stakeToken].logoUrl = logoUrl;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function emergencyWithdrawPool(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Partner / owner: fund rewards
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw reward seeds you deposited back to your wallet.
     *         Only withdraws from rewardPool (the seed/unfunded portion).
     *         Does NOT touch user staked principal — that is always safe.
     *
     *         Use case: you seeded REGAR pool with 100,000 REGAR.
     *         You want 50,000 back → call withdrawRewardSeed(REGAR, 50000e18)
     *         Remaining 50,000 stays as rewards for current stakers.
     *
     *         WARNING: If you withdraw more than pending rewards owed to
     *         current stakers, those stakers will receive less than expected.
     *         Always check getPoolInfo().rewardPool vs total pending rewards first.
     *
     * @param stakeToken  Which pool's reward fund to withdraw from
     * @param amount      Amount of rewardToken to pull back (use type(uint256).max for all)
     */
    function withdrawRewardSeed(address stakeToken, uint256 amount)
        external onlyOwner poolExists(stakeToken) nonReentrant
    {
        Pool storage p = pools[stakeToken];
        require(p.rewardPool > 0, "Reward pool is empty");
        uint256 toWithdraw = amount >= p.rewardPool ? p.rewardPool : amount;
        p.rewardPool -= toWithdraw;
        bool ok = IERC20(p.rewardToken).transfer(owner, toWithdraw);
        require(ok, "Transfer failed");
        emit RewardSeedWithdrawn(stakeToken, toWithdraw);
    }

    /**
     * @notice Deposit reward tokens into a pool's reward vault.
     *         Called by you (owner) to seed a pool, or by a partner to fund theirs.
     *         Caller must first approve(CONTRACT_ADDRESS, amount) on rewardToken.
     */
    function fundRewardPool(address stakeToken, uint256 amount)
        external onlyOwnerOrPartner(stakeToken) poolExists(stakeToken) nonReentrant
    {
        require(amount > 0, "Zero");
        Pool storage p = pools[stakeToken];
        bool ok = IERC20(p.rewardToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "Transfer failed");
        p.rewardPool += amount;
        emit RewardsFunded(stakeToken, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Owner: collect accumulated fees  ← THIS IS YOUR INCOME
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw accumulated protocol fees to your wallet.
     *         Fees build up automatically from every stake and unstake.
     *
     * @param token   The token whose fees you want to collect
     * @param amount  How much to collect (pass type(uint256).max for all)
     *
     * Example: after 1000 users stake 1000 REGAR each with 1% fee:
     *   ownerFeeVault[REGAR_ADDRESS] = 10,000 REGAR
     *   Call collectFees(REGAR_ADDRESS, 10000e18) → 10,000 REGAR sent to your wallet
     */
    function collectFees(address token, uint256 amount) external onlyOwner nonReentrant {
        uint256 available = ownerFeeVault[token];
        require(available > 0, "No fees to collect");
        uint256 toSend = amount >= available ? available : amount;
        ownerFeeVault[token] -= toSend;
        bool ok = IERC20(token).transfer(owner, toSend);
        require(ok, "Transfer failed");
        emit FeesCollected(token, owner, toSend);
    }

    /**
     * @notice Convenience: collect all fees for all pools at once.
     */
    function collectAllFees() external onlyOwner nonReentrant {
        for (uint256 i = 0; i < poolList.length; i++) {
            address t     = poolList[i];
            Pool storage p = pools[t];
            uint256 fee   = ownerFeeVault[p.rewardToken];
            if (fee > 0) {
                ownerFeeVault[p.rewardToken] = 0;
                IERC20(p.rewardToken).transfer(owner, fee);
                emit FeesCollected(p.rewardToken, owner, fee);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  User: stake
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Stake any supported ERC-20 token.
     *         A protocol fee is automatically deducted and sent to ownerFeeVault.
     *
     * @param stakeToken  Must have an active pool
     * @param amount      Gross amount (before fee). User approves this full amount.
     *
     * Flow:
     *   gross = 1000 REGAR
     *   fee   = 10 REGAR (1%)  → ownerFeeVault[REGAR] += 10
     *   net   = 990 REGAR      → your position.stakedAmount = 990
     */
    function stake(address stakeToken, uint256 amount)
        external poolActive(stakeToken) nonReentrant
    {
        require(amount > 0, "Zero amount");

        _checkpoint(msg.sender, stakeToken);

        Pool     storage p   = pools[stakeToken];
        Position storage pos = positions[msg.sender][stakeToken];

        // Pull full gross amount from user
        bool ok = IERC20(stakeToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "Transfer failed - approve first");

        // Calculate and route stake fee
        uint256 feeBps = _getStakeFeeBps(stakeToken);
        uint256 fee    = (amount * feeBps) / 10_000;
        uint256 net    = amount - fee;

        // Fee goes entirely to owner vault (stake fee is pure protocol income)
        if (fee > 0) {
            ownerFeeVault[stakeToken] += fee;
            p.totalFeesEarned         += fee;
        }

        pos.stakedAmount  += net;
        pos.stakeStartTime = pos.stakeStartTime == 0 ? block.timestamp : pos.stakeStartTime;
        p.totalStaked     += net;

        emit Staked(msg.sender, stakeToken, amount, net, fee);
    }

    // ─────────────────────────────────────────────────────────────────
    //  User: claim rewards
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Claim accumulated rewards. No fee on claims — full rewards to user.
     */
    function claim(address stakeToken)
        external poolActive(stakeToken) nonReentrant
    {
        Position storage pos = positions[msg.sender][stakeToken];
        Pool     storage p   = pools[stakeToken];

        require(pos.stakedAmount > 0, "Nothing staked");

        uint256 pending = _pendingRewards(msg.sender, stakeToken) + pos.rewardDebt;
        require(pending > 0, "No rewards yet");

        uint256 payout = pending > p.rewardPool ? p.rewardPool : pending;
        require(payout > 0, "Reward pool empty - contact pool owner");

        pos.rewardDebt     = 0;
        pos.stakeStartTime = block.timestamp;
        p.rewardPool      -= payout;

        bool ok = IERC20(p.rewardToken).transfer(msg.sender, payout);
        require(ok, "Transfer failed");

        emit Claimed(msg.sender, stakeToken, payout);
    }

    // ─────────────────────────────────────────────────────────────────
    //  User: unstake
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Unstake tokens + collect rewards. An unstake fee is applied to
     *         the principal — split between ownerFeeVault and rewardPool.
     *
     * @param stakeToken  Pool to exit
     * @param amount      Principal to unstake. Pass type(uint256).max for all.
     *
     * Flow (unstake 990 REGAR, 0.5% unstake fee):
     *   unstakeFee      = 4.95 REGAR
     *   → 2.475 REGAR  → ownerFeeVault  (your income)
     *   → 2.475 REGAR  → rewardPool     (auto-replenishes rewards for other stakers)
     *   user receives  = 985.05 REGAR + rewards
     */
    function unstake(address stakeToken, uint256 amount)
        external poolExists(stakeToken) nonReentrant
    {
        Position storage pos = positions[msg.sender][stakeToken];
        Pool     storage p   = pools[stakeToken];

        require(pos.stakedAmount > 0, "Nothing staked");

        uint256 toUnstake = amount >= pos.stakedAmount ? pos.stakedAmount : amount;
        require(toUnstake > 0, "Zero");

        uint256 rewards = _pendingRewards(msg.sender, stakeToken) + pos.rewardDebt;
        uint256 rewardPayout = rewards > p.rewardPool ? p.rewardPool : rewards;

        // Calculate unstake fee on principal
        uint256 feeBps        = _getUnstakeFeeBps(stakeToken);
        uint256 totalFee      = (toUnstake * feeBps) / 10_000;
        // Split fee: part to reward pool (sustainable), part to owner
        uint256 feeToRewards  = (totalFee * unstakeFeeToRewardPoolBps) / 10_000;
        uint256 feeToOwner    = totalFee - feeToRewards;
        uint256 netPrincipal  = toUnstake - totalFee;

        // Update state (checks-effects-interactions)
        pos.stakedAmount  -= toUnstake;
        pos.rewardDebt     = 0;
        pos.stakeStartTime = pos.stakedAmount > 0 ? block.timestamp : 0;
        p.totalStaked     -= toUnstake;
        if (rewardPayout > 0)  p.rewardPool      -= rewardPayout;
        if (feeToRewards  > 0) p.rewardPool      += feeToRewards; // auto-replenish
        if (feeToOwner    > 0) ownerFeeVault[stakeToken] += feeToOwner;
        if (totalFee      > 0) p.totalFeesEarned += totalFee;

        // Transfer net principal to user
        bool ok1 = IERC20(stakeToken).transfer(msg.sender, netPrincipal);
        require(ok1, "Principal transfer failed");

        // Transfer reward payout to user (reward token may differ from stake token)
        if (rewardPayout > 0) {
            bool ok2 = IERC20(p.rewardToken).transfer(msg.sender, rewardPayout);
            require(ok2, "Reward transfer failed");
        }

        emit Unstaked(msg.sender, stakeToken, netPrincipal, rewardPayout, totalFee);
    }

    // ─────────────────────────────────────────────────────────────────
    //  User: emergency exit (no rewards, minimal fee)
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Get your principal back immediately. Forfeits rewards.
     *         Works even when pool is paused.
     *         A reduced emergency fee (half normal unstake fee) still applies.
     */
    function emergencyExit(address stakeToken)
        external poolExists(stakeToken) nonReentrant
    {
        Position storage pos = positions[msg.sender][stakeToken];
        Pool     storage p   = pools[stakeToken];

        uint256 principal = pos.stakedAmount;
        require(principal > 0, "Nothing staked");

        uint256 feeBps       = _getUnstakeFeeBps(stakeToken) / 2; // half fee on emergency
        uint256 fee          = (principal * feeBps) / 10_000;
        uint256 netPrincipal = principal - fee;

        pos.stakedAmount   = 0;
        pos.rewardDebt     = 0;
        pos.stakeStartTime = 0;
        p.totalStaked     -= principal;
        if (fee > 0) ownerFeeVault[stakeToken] += fee;

        bool ok = IERC20(stakeToken).transfer(msg.sender, netPrincipal);
        require(ok, "Transfer failed");

        emit EmergencyExit(msg.sender, stakeToken, netPrincipal);
    }

    // ─────────────────────────────────────────────────────────────────
    //  View functions
    // ─────────────────────────────────────────────────────────────────

    function getPositionDetails(address user, address stakeToken)
        external view
        returns (
            uint256 stakedAmount,
            uint256 pendingRew,
            uint256 stakeStartTime,
            uint256 rewardPoolBal,
            uint256 aprBps,
            bool    paused
        )
    {
        Position storage pos = positions[user][stakeToken];
        Pool     storage p   = pools[stakeToken];
        stakedAmount   = pos.stakedAmount;
        pendingRew     = _pendingRewards(user, stakeToken) + pos.rewardDebt;
        stakeStartTime = pos.stakeStartTime;
        rewardPoolBal  = p.rewardPool;
        aprBps         = p.aprBps;
        paused         = p.paused;
    }

    function getAllPools() external view returns (address[] memory) {
        return poolList;
    }

    function getPoolInfo(address stakeToken)
        external view
        returns (
            address rewardToken,
            uint256 aprBps,
            uint256 rewardPool,
            uint256 totalStaked,
            bool    paused,
            address partner,
            string  memory name,
            string  memory logoUrl,
            uint256 stakeFeeBps,
            uint256 unstakeFeeBps,
            uint256 totalFeesEarned
        )
    {
        Pool storage p = pools[stakeToken];
        require(p.exists, "Pool does not exist");
        rewardToken     = p.rewardToken;
        aprBps          = p.aprBps;
        rewardPool      = p.rewardPool;
        totalStaked     = p.totalStaked;
        paused          = p.paused;
        partner         = p.partner;
        name            = p.name;
        logoUrl         = p.logoUrl;
        stakeFeeBps     = _getStakeFeeBps(stakeToken);
        unstakeFeeBps   = _getUnstakeFeeBps(stakeToken);
        totalFeesEarned = p.totalFeesEarned;
    }

    /**
     * @notice Total pending fees across all pools available for owner to collect.
     *         Returns (tokens[], amounts[]) arrays — one entry per unique reward token.
     */
    function getPendingFees()
        external view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens  = new address[](poolList.length);
        amounts = new uint256[](poolList.length);
        for (uint256 i = 0; i < poolList.length; i++) {
            address st   = poolList[i];
            address rt   = pools[st].rewardToken;
            tokens[i]    = rt;
            amounts[i]   = ownerFeeVault[rt];
        }
    }

    function poolCount() external view returns (uint256) {
        return poolList.length;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Convenience: fund multiple pools in one transaction
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fund multiple reward pools in a single transaction.
     *         Saves gas and time vs calling fundRewardPool() 4 times separately.
     *
     *         YOU MUST approve this contract on each token BEFORE calling this.
     *         Approve each token for its corresponding amount.
     *
     * @param stakeTokens  Array of pool stake token addresses
     * @param amounts      Array of reward amounts (must match stakeTokens length)
     *
     * Example — fund all 4 ARCHIEL pools at once:
     *   stakeTokens = [REGAR, USDC, EURC, ARCL]
     *   amounts     = [100000e18, 50000e6, 30000e6, 200000e18]
     *
     * This is equivalent to calling fundRewardPool() 4 times separately,
     * but in one transaction.
     */
    function fundMultiplePools(
        address[] calldata stakeTokens,
        uint256[] calldata amounts
    ) external onlyOwner nonReentrant {
        require(stakeTokens.length == amounts.length, "Length mismatch");
        require(stakeTokens.length > 0, "Empty arrays");

        for (uint256 i = 0; i < stakeTokens.length; i++) {
            address st = stakeTokens[i];
            uint256 amt = amounts[i];
            require(pools[st].exists, string(abi.encodePacked("Pool does not exist: index ", i)));
            require(amt > 0, "Zero amount in array");

            Pool storage p = pools[st];
            bool ok = IERC20(p.rewardToken).transferFrom(msg.sender, address(this), amt);
            require(ok, "Transfer failed");
            p.rewardPool += amt;
            emit RewardsFunded(st, msg.sender, amt);
        }
    }

    /**
     * @notice View how much reward seed you have deposited per pool,
     *         and how much total is owed to current stakers (approximate).
     *         Helps you decide how much is safe to withdraw.
     *
     * @param stakeToken  Pool to check
     * @return rewardPoolBal    Current reward tokens available in the pool
     * @return totalStaked      Total user principal staked
     * @return aprBps           Current APR in basis points
     * @return safeToWithdraw   Rough estimate of reward seed you can safely pull back
     *                          (rewardPool minus ~30 days of rewards for current stakers)
     */
    function getRewardPoolHealth(address stakeToken)
        external view poolExists(stakeToken)
        returns (
            uint256 rewardPoolBal,
            uint256 totalStaked,
            uint256 aprBps,
            uint256 safeToWithdraw
        )
    {
        Pool storage p = pools[stakeToken];
        rewardPoolBal = p.rewardPool;
        totalStaked   = p.totalStaked;
        aprBps        = p.aprBps;

        // Estimate 30-day reward obligation for all current stakers
        uint256 thirtyDayRewards = (p.totalStaked * p.aprBps * 30 days) / (10_000 * 365 days);
        safeToWithdraw = rewardPoolBal > thirtyDayRewards
            ? rewardPoolBal - thirtyDayRewards
            : 0;
    }
}
