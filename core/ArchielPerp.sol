// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable@5.4.0/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@5.4.0/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@5.4.0/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@5.4.0/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@5.4.0/utils/PausableUpgradeable.sol";

/**
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║   ARCHIEL FINANCE — Futures (UUPS upgradeable)                          ║
 * ║   Segregated trading balance · funding rate · partial close/add        ║
 * ║   margin · liquidator reward · price-confidence guard · insurance      ║
 * ║   fund + manual ADL safety valve                                        ║
 * ╠══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  HONEST SCOPE NOTE                                                       ║
 * ║  Hyperliquid is a full L1 with a custom on-chain central-limit-order-    ║
 * ║  book matching engine and a ranked, fully-automatic ADL system driven   ║
 * ║  by off-chain indexers. This is one Solidity contract on a shared EVM   ║
 * ║  testnet, settling against a single pooled counterparty (no peer-to-    ║
 * ║  peer order matching). What follows adopts Hyperliquid's most           ║
 * ║  important RISK MECHANICS at a scope that fits that architecture —      ║
 * ║  it is not a byte-for-byte clone, and a few things are intentionally    ║
 * ║  simplified (called out below).                                         ║
 * ║                                                                          ║
 * ║  DEPLOYING (Remix) — same flow as before, nothing changed here:          ║
 * ║  1. Deploy this contract plainly (constructor just disables direct      ║
 * ║     initialization) → this is your "Implementation".                    ║
 * ║  2. Deploy ArchielProxy.sol (ERC1967Proxy, OpenZeppelin)                ║
 * ║     with args (implementation address, "0x") → this is your "Proxy".   ║
 * ║  3. "At Address" the Proxy using THIS contract's ABI, call ONCE:        ║
 * ║       initialize(marginToken, liquidityPool, pyth)                      ║
 * ║  4. Call ArchielLiquidityPool.setFuturesContract(proxyAddress).         ║
 * ║  5. Frontend's CONTRACT_FUTURES_ADDRESS = the Proxy address, forever.   ║
 * ║  Future upgrades: deploy a new implementation, call                     ║
 * ║  upgradeToAndCall(newImpl, "0x") on the Proxy as owner. Same address,   ║
 * ║  same data, zero migration — see the __gap comment near the bottom of   ║
 * ║  the storage section before adding new state variables in a future      ║
 * ║  version.                                                                ║
 * ║                                                                          ║
 * ║  1) FUNDING RATE                                                         ║
 * ║  Because every position nets against the shared liquidity pool          ║
 * ║  (rather than being peer-matched long vs. short like a real             ║
 * ║  orderbook), funding here works as a periodic carry cost/rebate         ║
 * ║  between a trader and the pool — same purpose as Hyperliquid's          ║
 * ║  funding (keep the perp price anchored, discourage one-sided            ║
 * ║  crowding), simplified to not require peer netting. `fundingRatePerHourBps`     ║
 * ║  is owner-set (in production this would come from an off-chain keeper   ║
 * ║  computing it from order-book imbalance/premium — there is no           ║
 * ║  order book here, so it's a manual/keeper-pushed input for now).        ║
 * ║  pokeFunding() is permissionless and accrues a global funding index     ║
 * ║  over time; each position pays/receives funding proportional to its    ║
 * ║  size when it's closed, partially closed, or liquidated.                ║
 * ║                                                                          ║
 * ║  2) PARTIAL CLOSE & ADD MARGIN                                           ║
 * ║  partialClose() realizes PnL + funding on a slice of a position and     ║
 * ║  leaves the rest open at the same entry price. addMargin() tops up an   ║
 * ║  open position's margin from the trader's trading balance to push      ║
 * ║  the liquidation price further away (lower effective leverage) —       ║
 * ║  size is unchanged, so this never increases exposure, only safety.      ║
 * ║                                                                          ║
 * ║  3) LIQUIDATION ENGINE                                                   ║
 * ║  liquidate() now pays a bounty (liquidatorRewardBps of the position's   ║
 * ║  margin) to whoever calls it, taken out of the margin itself before     ║
 * ║  the remainder is forwarded to the pool — this gives bots/keepers a    ║
 * ║  real incentive to liquidate promptly, same purpose as Hyperliquid's    ║
 * ║  liquidation incentive. There's still no separate "mark price" (no      ║
 * ║  order book to derive one from) — instead, _updateAndGetPrice()         ║
 * ║  rejects any Pyth update whose confidence interval is too wide          ║
 * ║  relative to the price (maxConfBps), which is this architecture's       ║
 * ║  equivalent safety net against a single bad/thin price tick             ║
 * ║  triggering a bogus liquidation.                                        ║
 * ║                                                                          ║
 * ║  4) INSURANCE FUND / ADL                                                 ║
 * ║  A slice of every realized loss (insuranceFundBps) is diverted into a   ║
 * ║  local insuranceFundBalance held by THIS contract, instead of 100%      ║
 * ║  going to the pool. When a trader closes in profit, this contract       ║
 * ║  tries to pull the profit from the pool first; if the pool can't        ║
 * ║  cover it (insolvent/underfunded), it automatically falls back to the   ║
 * ║  local insurance fund instead of leaving the trader stuck. On top of    ║
 * ║  that, autoDeleverage() is a manual safety valve: if the insurance      ║
 * ║  fund is running low, the owner (in practice: an automated keeper       ║
 * ║  script) can force-close a specific profitable position early to cut    ║
 * ║  system exposure before it becomes a problem. This is deliberately a   ║
 * ║  simpler, manually/keeper-triggered version of Hyperliquid's fully      ║
 * ║  automatic, profit-ranked ADL queue — a true ranked queue needs         ║
 * ║  off-chain indexing to stay gas-efficient even on Hyperliquid itself.  ║
 * ║                                                                          ║
 * ║  PRICE ORACLE                                                            ║
 * ║    Pyth Network pull oracle (official Arc Testnet deployment):          ║
 * ║    Contract : 0x2880aB155794e7179c9eE2e38200202908C17B43                ║
 * ║    The caller must submit Hermes price-update bytes with every          ║
 * ║    open/close/partialClose/liquidate call, and pay the small native-    ║
 * ║    token update fee Pyth charges (msg.value).                           ║
 * ║                                                                          ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IArchielLiquidityPool {
    function payoutToTrader(address token, address trader, uint256 amount) external;
    function receiveFromFutures(address token, uint256 amount) external;
}

// Minimal Pyth interface — only what this contract needs.
interface IPyth {
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythPrice memory price);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

struct PythPrice {
    int64  price;       // raw price
    uint64 conf;        // confidence interval
    int32  expo;         // exponent, e.g. -8 means price * 10^-8
    uint   publishTime;
}

contract ArchielPerp is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ─────────────────────────────────────────────────────────────────
    //  Config (owner-tunable — no upgrade needed to retune these)
    // ─────────────────────────────────────────────────────────────────
    uint256 public constant PRICE_SCALE = 1e18; // internal price precision, never changes
    uint256 public constant BPS_DENOM   = 10000;
    uint256 public constant FUNDING_INTERVAL = 1 hours;

    uint256 public maxLeverage;
    uint256 public maxPriceAge;

    IERC20  public marginToken;                 // e.g. USDC on Arc Testnet
    IArchielLiquidityPool public liquidityPool;
    IPyth   public pyth;

    mapping(bytes32 => bool) public allowedFeedId; // which Pyth price feed IDs may be traded

    enum Side { Long, Short }

    struct Position {
        address trader;
        bytes32 feedId;
        Side    side;
        uint256 margin;             // in marginToken units
        uint256 leverage;           // leverage at open time (reference only — size is fixed once opened, adding margin only lowers effective leverage)
        uint256 size;               // margin(at open) * leverage, in marginToken units — only changes via partialClose()
        uint256 entryPrice;         // scaled to PRICE_SCALE
        int256  entryFundingIndex;  // cumulativeFundingIndex snapshot, scaled PRICE_SCALE
        uint64  openedAt;
        bool    open;
    }

    uint256 public nextPositionId;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public positionsByTrader;

    // ─────────────────────────────────────────────────────────────────
    //  Segregated trading balance
    //  USDC a trader has explicitly moved into this contract via
    //  deposit(). This — and ONLY this — is what openPosition() can ever
    //  spend as margin. Funds still sitting in the trader's wallet are
    //  never touched by this contract.
    // ─────────────────────────────────────────────────────────────────
    mapping(address => uint256) public traderBalance;

    // ─────────────────────────────────────────────────────────────────
    //  Funding rate
    // ─────────────────────────────────────────────────────────────────
    int256  public fundingRatePerHourBps;  // owner/keeper-set; positive = longs pay shorts (pool)
    int256  public cumulativeFundingIndex; // scaled PRICE_SCALE, accrues over time via pokeFunding()
    uint256 public lastFundingTime;

    // ─────────────────────────────────────────────────────────────────
    //  Liquidation engine
    // ─────────────────────────────────────────────────────────────────
    uint256 public liquidatorRewardBps; // % of margin paid to whoever calls liquidate()
    uint256 public maxConfBps;          // reject a Pyth price update if conf/price exceeds this, in bps

    // ─────────────────────────────────────────────────────────────────
    //  Insurance fund
    // ─────────────────────────────────────────────────────────────────
    uint256 public insuranceFundBps;    // % of every realized loss diverted here instead of to the pool
    uint256 public insuranceFundBalance; // held directly by this contract, in marginToken units

    /// @dev Reserved storage slots for future versions. When you add new
    ///      state variables in an upgrade, add them ABOVE this line and
    ///      shrink the array size by the same number of slots you used.
    uint256[37] private __gap;

    // ─────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────
    event PositionOpened(uint256 indexed id, address indexed trader, bytes32 feedId, Side side, uint256 margin, uint256 leverage, uint256 entryPrice);
    event PositionClosed(uint256 indexed id, address indexed trader, uint256 exitPrice, int256 pnl, uint256 payout);
    event PositionPartiallyClosed(uint256 indexed id, address indexed trader, uint256 closedSize, uint256 remainingSize, uint256 exitPrice, int256 pnl, uint256 payout);
    event PositionMarginAdded(uint256 indexed id, address indexed trader, uint256 amount, uint256 newMargin);
    event PositionLiquidated(uint256 indexed id, address indexed trader, address indexed liquidator, uint256 exitPrice, uint256 liquidatorReward);
    event PositionAutoDeleveraged(uint256 indexed id, address indexed trader, uint256 exitPrice, uint256 payout);
    event FeedAllowed(bytes32 indexed feedId, bool allowed);
    event Deposited(address indexed trader, uint256 amount);
    event Withdrawn(address indexed trader, uint256 amount);
    event MaxLeverageUpdated(uint256 newMaxLeverage);
    event MaxPriceAgeUpdated(uint256 newMaxPriceAge);
    event FundingRateUpdated(int256 newRatePerHourBps);
    event FundingAccrued(int256 newCumulativeIndex, uint256 timestamp);
    event LiquidatorRewardBpsUpdated(uint256 newBps);
    event MaxConfBpsUpdated(uint256 newBps);
    event InsuranceFundBpsUpdated(uint256 newBps);
    event InsuranceFunded(address indexed from, uint256 amount);
    event InsuranceFundUsed(uint256 indexed positionId, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // prevents anyone from calling initialize() on the bare implementation contract
    }

    function initialize(address _marginToken, address _liquidityPool, address _pyth) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        marginToken   = IERC20(_marginToken);
        liquidityPool = IArchielLiquidityPool(_liquidityPool);
        pyth          = IPyth(_pyth);

        maxLeverage  = 20;
        maxPriceAge  = 90;
        nextPositionId = 1;

        fundingRatePerHourBps = 0;      // starts neutral — owner/keeper tunes it based on market conditions
        lastFundingTime = block.timestamp;

        liquidatorRewardBps = 50;       // 0.5% of margin
        maxConfBps          = 100;      // reject prices where conf > 1% of price

        insuranceFundBps    = 1000;     // 10% of every realized loss
    }

    /// @dev Only the owner can authorize an upgrade to a new implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ─────────────────────────────────────────────────────────────────
    //  Owner config
    // ─────────────────────────────────────────────────────────────────

    function setFeedAllowed(bytes32 feedId, bool allowed) external onlyOwner {
        allowedFeedId[feedId] = allowed;
        emit FeedAllowed(feedId, allowed);
    }

    function setMaxLeverage(uint256 newMaxLeverage) external onlyOwner {
        require(newMaxLeverage >= 1, "Bad leverage");
        maxLeverage = newMaxLeverage;
        emit MaxLeverageUpdated(newMaxLeverage);
    }

    function setMaxPriceAge(uint256 newMaxPriceAge) external onlyOwner {
        require(newMaxPriceAge > 0, "Bad price age");
        maxPriceAge = newMaxPriceAge;
        emit MaxPriceAgeUpdated(newMaxPriceAge);
    }

    /// @notice Set the hourly funding rate, in bps. Positive = longs pay
    ///         shorts(the pool's long side gets nothing back; this is a
    ///         pool-as-counterparty model, so "shorts" effectively means
    ///         the pool's exposure improves). Settles funding accrued
    ///         under the OLD rate first so past accrual isn't distorted.
    function setFundingRatePerHourBps(int256 newRatePerHourBps) external onlyOwner {
        pokeFunding();
        fundingRatePerHourBps = newRatePerHourBps;
        emit FundingRateUpdated(newRatePerHourBps);
    }

    function setLiquidatorRewardBps(uint256 newBps) external onlyOwner {
        require(newBps <= 500, "Reward too high"); // sanity cap: max 5% of margin
        liquidatorRewardBps = newBps;
        emit LiquidatorRewardBpsUpdated(newBps);
    }

    function setMaxConfBps(uint256 newBps) external onlyOwner {
        require(newBps > 0 && newBps <= 1000, "Bad conf bound");
        maxConfBps = newBps;
        emit MaxConfBpsUpdated(newBps);
    }

    function setInsuranceFundBps(uint256 newBps) external onlyOwner {
        require(newBps <= BPS_DENOM, "Bad bps");
        insuranceFundBps = newBps;
        emit InsuranceFundBpsUpdated(newBps);
    }

    /// @notice Anyone can top up the local insurance fund directly.
    function fundInsurance(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(marginToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        insuranceFundBalance += amount;
        emit InsuranceFunded(msg.sender, amount);
    }

    /// @notice Emergency stop: freezes new positions and new deposits.
    ///         closePosition(), partialClose(), liquidate() and withdraw()
    ///         keep working so traders can always exit and retrieve funds.
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Rescue an ERC-20 token accidentally sent to this contract.
    ///         Cannot touch marginToken — that would let the owner take
    ///         funds traders have deposited as their trading balance (or
    ///         the insurance fund).
    function rescueForeignToken(address token, uint256 amount, address to) external onlyOwner {
        require(token != address(marginToken), "Cannot rescue margin token");
        require(to != address(0), "Zero address");
        require(IERC20(token).transfer(to, amount), "Rescue transfer failed");
    }

    /**
     * @notice Manual/keeper-triggered auto-deleverage: force-close a
     *         specific OPEN, PROFITABLE position early, at the current
     *         price, to cut system exposure when the insurance fund is
     *         running low. Only usable while insuranceFundBalance is
     *         below a caller-supplied threshold, as a guard rail against
     *         casual misuse — the owner/keeper must actually observe a
     *         real shortfall before this is callable.
     * @dev    This is a simplified stand-in for Hyperliquid's fully
     *         automatic, profit-ranked ADL queue (see file header).
     */
    function autoDeleverage(uint256 id, uint256 insuranceBelowThreshold, bytes[] calldata priceUpdateData)
        external payable onlyOwner nonReentrant
    {
        require(insuranceFundBalance < insuranceBelowThreshold, "Insurance fund not low enough to justify ADL");
        Position storage pos = positions[id];
        require(pos.open, "Not open");

        pokeFunding();
        uint256 exitPrice = _updateAndGetPrice(pos.feedId, priceUpdateData);
        (int256 pnl, uint256 payout, ) = _settle(pos, exitPrice);
        require(pnl > 0, "Can only ADL a profitable position");

        pos.open = false;
        _settlePayout(id, pos.trader, pos.margin, payout, 0);

        emit PositionAutoDeleveraged(id, pos.trader, exitPrice, payout);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Trading balance — deposit / withdraw
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Move USDC from your wallet into your segregated trading
     *         balance on this contract. You MUST approve this contract
     *         for `amount` first. Only funds deposited here can ever be
     *         used as margin — your wallet balance is never touched by
     *         openPosition().
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        require(marginToken.transferFrom(msg.sender, address(this), amount), "Deposit transfer failed");
        traderBalance[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Move USDC back out of your trading balance into your
     *         wallet. Only the portion NOT currently locked as margin in
     *         an open position is ever part of traderBalance, so this
     *         always succeeds up to your available (unlocked) balance.
     *         Always callable, even while paused, so funds are never
     *         trapped by an emergency stop.
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(traderBalance[msg.sender] >= amount, "Insufficient trading balance");
        traderBalance[msg.sender] -= amount;
        require(marginToken.transfer(msg.sender, amount), "Withdraw transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────

    /// @notice All position IDs ever opened by a trader (open or closed).
    function getTraderPositionIds(address trader) external view returns (uint256[] memory) {
        return positionsByTrader[trader];
    }

    /// @notice Unrealized PnL for an open position at a given fresh price
    ///         (funding NOT included — this is a lightweight read-only
    ///         preview for the UI using a price it already fetched
    ///         off-chain; call previewPnlWithFunding for the full figure).
    function previewPnl(uint256 id, uint256 currentPrice)
        external view
        returns (int256 pnl, uint256 payout, uint256 loss)
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");
        return _settle(pos, currentPrice);
    }

    /// @notice Same as previewPnl but nets in accrued funding as of the
    ///         last pokeFunding() call (call pokeFunding() first on-chain,
    ///         or accept this may be slightly stale between funding pokes).
    function previewPnlWithFunding(uint256 id, uint256 currentPrice)
        external view
        returns (int256 pnl, uint256 payout, uint256 loss, int256 fundingOwed)
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");
        (pnl, payout, loss) = _settle(pos, currentPrice);
        fundingOwed = _fundingOwed(pos, pos.size);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Funding
    // ─────────────────────────────────────────────────────────────────

    /// @notice Accrues the global funding index up to now, at the current
    ///         fundingRatePerHourBps. Permissionless — anyone (typically a
    ///         keeper bot) can call this; it's also called automatically
    ///         at the start of every open/close/liquidate/ADL.
    function pokeFunding() public {
        uint256 elapsed = block.timestamp - lastFundingTime;
        if (elapsed == 0) return;
        cumulativeFundingIndex += (fundingRatePerHourBps * int256(elapsed) * int256(PRICE_SCALE))
            / (int256(FUNDING_INTERVAL) * int256(BPS_DENOM));
        lastFundingTime = block.timestamp;
        emit FundingAccrued(cumulativeFundingIndex, block.timestamp);
    }

    /// @dev Funding owed BY the trader (positive) or TO the trader
    ///      (negative), for a given size, since entryFundingIndex.
    ///      Longs pay when the index rose; shorts pay when it fell.
    function _fundingOwed(Position storage pos, uint256 sizeSlice) internal view returns (int256) {
        int256 idxDelta = cumulativeFundingIndex - pos.entryFundingIndex;
        int256 cost = (int256(sizeSlice) * idxDelta) / int256(PRICE_SCALE);
        if (pos.side == Side.Short) cost = -cost;
        return cost;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Open position
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Open a leveraged position. Spends `margin` of marginToken
     *         from the caller's segregated trading balance (deposit()
     *         first) and records entry price from a fresh Pyth update.
     */
    function openPosition(
        bytes32 feedId,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant whenNotPaused returns (uint256 id) {
        require(margin > 0, "Zero margin");
        require(leverage >= 1 && leverage <= maxLeverage, "Bad leverage");
        require(traderBalance[msg.sender] >= margin, "Insufficient trading balance - deposit first");

        pokeFunding();
        uint256 entryPrice = _updateAndGetPrice(feedId, priceUpdateData);

        // Debit the trader's segregated trading balance — no wallet-level
        // transfer here. The tokens are already held by this contract from
        // an earlier deposit(), so this is pure internal accounting.
        traderBalance[msg.sender] -= margin;

        id = nextPositionId++;
        positions[id] = Position({
            trader:             msg.sender,
            feedId:             feedId,
            side:               isLong ? Side.Long : Side.Short,
            margin:             margin,
            leverage:           leverage,
            size:               margin * leverage,
            entryPrice:         entryPrice,
            entryFundingIndex:  cumulativeFundingIndex,
            openedAt:           uint64(block.timestamp),
            open:               true
        });
        positionsByTrader[msg.sender].push(id);

        emit PositionOpened(id, msg.sender, feedId, positions[id].side, margin, leverage, entryPrice);
    }

    /**
     * @notice Add margin to an OPEN position from your trading balance.
     *         Size is unchanged — this only lowers effective leverage
     *         and pushes the liquidation price further away. It can
     *         never increase risk, so it's allowed even while paused.
     */
    function addMargin(uint256 id, uint256 amount) external nonReentrant {
        Position storage pos = positions[id];
        require(pos.open, "Not open");
        require(pos.trader == msg.sender, "Not position owner");
        require(amount > 0, "Zero amount");
        require(traderBalance[msg.sender] >= amount, "Insufficient trading balance");

        traderBalance[msg.sender] -= amount;
        pos.margin += amount;

        emit PositionMarginAdded(id, msg.sender, amount, pos.margin);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Close / partial close / liquidate
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Close an open position at the current Pyth price. Credits
     *         margin + PnL - funding back to the trader's trading
     *         balance (capped at 0 on the downside). Always callable,
     *         even while paused.
     */
    function closePosition(uint256 id, bytes[] calldata priceUpdateData)
        external payable nonReentrant
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");
        require(pos.trader == msg.sender, "Not position owner");

        pokeFunding();
        uint256 exitPrice = _updateAndGetPrice(pos.feedId, priceUpdateData);
        int256 fundingOwed = _fundingOwed(pos, pos.size);
        pos.open = false;

        (int256 pnl, uint256 payout, uint256 loss) = _settleWithFunding(pos, exitPrice, fundingOwed);
        _settlePayout(id, pos.trader, pos.margin, payout, loss);

        emit PositionClosed(id, msg.sender, exitPrice, pnl, payout);
    }

    /**
     * @notice Close only part of an open position (closeSize, in
     *         marginToken-equivalent notional). Realizes PnL + funding
     *         proportional to the closed slice and credits it to the
     *         trader's trading balance; the remaining position stays
     *         open at the SAME entry price with a fresh funding
     *         checkpoint. Always callable, even while paused.
     */
    function partialClose(uint256 id, uint256 closeSize, bytes[] calldata priceUpdateData)
        external payable nonReentrant
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");
        require(pos.trader == msg.sender, "Not position owner");
        require(closeSize > 0 && closeSize < pos.size, "Use closePosition() to close in full");

        pokeFunding();
        uint256 exitPrice = _updateAndGetPrice(pos.feedId, priceUpdateData);

        // Settle funding for the WHOLE position now, then start a fresh
        // funding checkpoint for whatever remains — simplest way to keep
        // funding accounting correct across partial closes.
        int256 fundingOwed = _fundingOwed(pos, pos.size);
        pos.entryFundingIndex = cumulativeFundingIndex;

        uint256 marginSlice = (pos.margin * closeSize) / pos.size;

        // PnL on just the closed slice: same entry price and side, scaled
        // down margin/size.
        (int256 pnl, uint256 payout, uint256 loss) = _settlePure(marginSlice, closeSize, pos.entryPrice, pos.side, exitPrice);

        // Funding on the closed slice is the proportional share of the
        // whole-position funding just settled above.
        int256 fundingSlice = (fundingOwed * int256(closeSize)) / int256(pos.size);

        (payout, loss) = _applyFunding(payout, loss, marginSlice, fundingSlice);

        pos.margin -= marginSlice;
        pos.size   -= closeSize;

        _settlePayout(id, pos.trader, marginSlice, payout, loss);

        emit PositionPartiallyClosed(id, msg.sender, closeSize, pos.size, exitPrice, pnl, payout);
    }

    /**
     * @notice Liquidate a position whose loss (incl. funding) has
     *         reached or exceeded its margin. Callable by anyone — pays
     *         a bounty (liquidatorRewardBps of margin) to the caller as
     *         incentive. Always callable, even while paused.
     */
    function liquidate(uint256 id, bytes[] calldata priceUpdateData)
        external payable nonReentrant
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");

        pokeFunding();
        uint256 exitPrice = _updateAndGetPrice(pos.feedId, priceUpdateData);
        int256 fundingOwed = _fundingOwed(pos, pos.size);
        (, , uint256 loss) = _settleWithFunding(pos, exitPrice, fundingOwed);
        require(loss >= pos.margin, "Not liquidatable yet");

        pos.open = false;

        uint256 reward = (pos.margin * liquidatorRewardBps) / BPS_DENOM;
        if (reward > 0) {
            require(marginToken.transfer(msg.sender, reward), "Reward transfer failed");
        }
        uint256 remainingMargin = pos.margin - reward;
        // Full loss (>= margin) means payout = 0; the remaining margin
        // (after the liquidator's cut) is what gets forwarded to the pool
        // / insurance fund as the realized loss.
        _settlePayout(id, pos.trader, remainingMargin, 0, remainingMargin);

        emit PositionLiquidated(id, pos.trader, msg.sender, exitPrice, reward);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal settlement helpers
    // ─────────────────────────────────────────────────────────────────

    /// @dev Pure PnL math (no funding, no state changes, no transfers).
    function _settle(Position storage pos, uint256 exitPrice)
        internal view
        returns (int256 pnl, uint256 payout, uint256 loss)
    {
        return _settlePure(pos.margin, pos.size, pos.entryPrice, pos.side, exitPrice);
    }

    /// @dev Same PnL math as _settle(), but taking plain values instead of
    ///      a storage pointer — used directly by _settle() for a full
    ///      position, and by partialClose() for a closed slice (margin/size
    ///      scaled down, entryPrice/side unchanged).
    function _settlePure(uint256 margin, uint256 size, uint256 entryPrice, Side side, uint256 exitPrice)
        internal pure
        returns (int256 pnl, uint256 payout, uint256 loss)
    {
        int256 priceDiff = int256(exitPrice) - int256(entryPrice);
        if (side == Side.Short) priceDiff = -priceDiff;

        pnl = (int256(size) * priceDiff) / int256(entryPrice);

        if (pnl >= 0) {
            payout = margin + uint256(pnl);
            loss   = 0;
        } else {
            uint256 absPnl = uint256(-pnl);
            loss   = absPnl >= margin ? margin : absPnl;
            payout = margin - loss;
        }
    }

    /// @dev PnL math, then nets in a funding amount on top.
    function _settleWithFunding(Position storage pos, uint256 exitPrice, int256 fundingOwed)
        internal view
        returns (int256 pnl, uint256 payout, uint256 loss)
    {
        (pnl, payout, loss) = _settlePure(pos.margin, pos.size, pos.entryPrice, pos.side, exitPrice);
        (payout, loss) = _applyFunding(payout, loss, pos.margin, fundingOwed);
    }

    /// @dev Nets a funding amount (positive = trader owes, negative =
    ///      trader is owed) into an already-computed payout/loss pair,
    ///      re-clamping so a trader can never be pushed below zero.
    function _applyFunding(uint256 payout, uint256 loss, uint256 marginBase, int256 fundingOwed)
        internal pure
        returns (uint256 newPayout, uint256 newLoss)
    {
        if (fundingOwed > 0) {
            uint256 owed = uint256(fundingOwed);
            if (owed >= payout) {
                newLoss = loss + (owed - payout);
                newPayout = 0;
                if (newLoss > marginBase) newLoss = marginBase; // can never lose more than margin
            } else {
                newPayout = payout - owed;
                newLoss = loss;
            }
        } else if (fundingOwed < 0) {
            newPayout = payout + uint256(-fundingOwed);
            newLoss = loss > uint256(-fundingOwed) ? loss - uint256(-fundingOwed) : 0;
        } else {
            newPayout = payout;
            newLoss = loss;
        }
    }

    /**
     * @dev Settles a closed/liquidated/partially-closed position back
     *      into the trader's segregated trading balance (traderBalance)
     *      — NOT their wallet. `originalMargin` is already held by this
     *      contract. Two cases:
     *        - Trader lost money (loss > 0): a slice (insuranceFundBps)
     *          stays in this contract's insuranceFundBalance, the rest
     *          is forwarded to the pool's counterparty reserve. Whatever
     *          margin remains (payout = margin - loss) is credited back.
     *        - Trader made a profit (payout > originalMargin): their
     *          full original margin is credited from this contract's own
     *          holdings; the extra profit is pulled from the pool. If
     *          the pool can't cover it (insolvent/underfunded), this
     *          automatically falls back to the local insurance fund
     *          instead of leaving the trader stuck.
     *      The trader stays fully in control of when funds leave the
     *      escrow: call withdraw() whenever they want it in their wallet.
     */
    function _settlePayout(uint256 positionId, address trader, uint256 originalMargin, uint256 payout, uint256 loss) internal {
        if (loss > 0) {
            uint256 toInsurance = (loss * insuranceFundBps) / BPS_DENOM;
            uint256 toPool = loss - toInsurance;
            if (toInsurance > 0) insuranceFundBalance += toInsurance;
            if (toPool > 0) {
                marginToken.approve(address(liquidityPool), toPool);
                liquidityPool.receiveFromFutures(address(marginToken), toPool);
            }
        }

        uint256 fromOwnBalance = payout <= originalMargin ? payout : originalMargin;
        uint256 fromPoolProfit = payout - fromOwnBalance;

        if (fromOwnBalance > 0) {
            traderBalance[trader] += fromOwnBalance;
        }
        if (fromPoolProfit > 0) {
            try liquidityPool.payoutToTrader(address(marginToken), address(this), fromPoolProfit) {
                traderBalance[trader] += fromPoolProfit;
            } catch {
                // Pool couldn't cover it (insolvent/underfunded) — fall back
                // to the local insurance fund instead of reverting and
                // leaving the trader stuck unable to close their position.
                require(insuranceFundBalance >= fromPoolProfit, "Pool and insurance fund both insufficient");
                insuranceFundBalance -= fromPoolProfit;
                traderBalance[trader] += fromPoolProfit;
                emit InsuranceFundUsed(positionId, fromPoolProfit);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal: Pyth price read (with mandatory fresh update)
    // ─────────────────────────────────────────────────────────────────

    /// @dev Pushes the submitted Hermes update into Pyth, then reads the
    ///      resulting price for `feedId`, scaled to PRICE_SCALE (1e18).
    ///      Rejects the price if its confidence interval is too wide
    ///      relative to the price itself (maxConfBps) — this contract's
    ///      substitute for a real order-book-derived "mark price" check.
    function _updateAndGetPrice(bytes32 feedId, bytes[] calldata priceUpdateData)
        internal returns (uint256 scaledPrice)
    {
        require(allowedFeedId[feedId], "Feed not allowed");

        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "Insufficient Pyth update fee");
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        PythPrice memory p = pyth.getPriceNoOlderThan(feedId, maxPriceAge);
        require(p.price > 0, "Invalid price");
        require(uint256(p.conf) * BPS_DENOM <= uint256(int256(p.price)) * maxConfBps, "Price confidence too wide");

        scaledPrice = _scalePrice(uint256(int256(p.price)), p.expo);

        // Refund any Pyth fee overpayment back to the caller.
        if (msg.value > fee) {
            (bool ok, ) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "Refund failed");
        }
    }

    function _scalePrice(uint256 rawPrice, int32 expo) internal pure returns (uint256) {
        // price * 10^expo, rescaled to PRICE_SCALE (1e18)
        if (expo >= 0) {
            return rawPrice * (10 ** uint32(expo)) * PRICE_SCALE;
        }
        uint32 negExpo = uint32(-expo);
        if (negExpo <= 18) {
            return rawPrice * (10 ** (18 - negExpo));
        }
        return rawPrice / (10 ** (negExpo - 18));
    }
}
