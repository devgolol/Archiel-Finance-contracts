// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║         ARCHIEL FINANCE — Futures V1 (margin custody + Pyth settlement) ║
 * ╠══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  WHAT THIS FIXES                                                         ║
 * ║  The previous frontend "locked" futures margin by calling                ║
 * ║  depositLiquidity() on the liquidity pool contract — which actually     ║
 * ║  just credits a swap-pair reserve. There was no on-chain record of       ║
 * ║  who opened what position, and closePosition() never returned funds.    ║
 * ║  This contract gives every position a real on-chain record and a real   ║
 * ║  on-chain payout when it is closed or liquidated.                       ║
 * ║                                                                          ║
 * ║  HOW IT WORKS                                                            ║
 * ║  ─────────────────────────────────────────────────────────────────────  ║
 * ║  1. Trader approves this contract for `margin` USDC, then calls          ║
 * ║     openPosition() with a Pyth price update — margin is pulled in.      ║
 * ║  2. Entry price = the fresh Pyth price submitted at open time.          ║
 * ║  3. Trader calls closePosition() with a fresh Pyth price update.        ║
 * ║     PnL = size * (exitPrice - entryPrice) / entryPrice  (sign flips     ║
 * ║     for shorts). margin + PnL is paid back to the trader.               ║
 * ║  4. If a trader's loss would exceed their margin, anyone can call       ║
 * ║     liquidate() once the loss threshold is crossed.                     ║
 * ║  5. Profits are paid out of, and losses are paid into, a SEPARATE       ║
 * ║     futures counterparty pool on ArchielLiquidityPool — never the       ║
 * ║     swap-pair reserves that back LPs' principal.                        ║
 * ║                                                                          ║
 * ║  PRICE ORACLE                                                            ║
 * ║    Pyth Network pull oracle (official Arc Testnet deployment):          ║
 * ║    Contract : 0x2880aB155794e7179c9eE2e38200202908C17B43                ║
 * ║    Feed IDs : BTC/USD 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72... ║
 * ║               ETH/USD 0xff61491a931112ddf1bd8147cd1b641375f79f5825...   ║
 * ║    The caller must submit Hermes price-update bytes with every          ║
 * ║    open/close/liquidate call, and pay the small native-token update    ║
 * ║    fee Pyth charges (msg.value).                                        ║
 * ║                                                                          ║
 * ║  RISK NOTES (read before funding the counterparty pool)                 ║
 * ║    - This is a simple, UNAUDITED v1: no funding rate, no partial        ║
 * ║      close, no per-pair open-interest caps beyond MAX_LEVERAGE.         ║
 * ║    - The counterparty pool can be insolvent if aggregate trader         ║
 * ║      profits exceed what owner/LPs funded into it — payoutToTrader()    ║
 * ║      will simply revert if funds are insufficient, leaving a winning    ║
 * ║      trader temporarily unable to close until the pool is topped up.   ║
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

contract ArchielFutures {

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
    //  Config
    // ─────────────────────────────────────────────────────────────────
    uint256 public constant MAX_LEVERAGE   = 20;
    uint256 public constant PRICE_SCALE    = 1e18;   // internal price precision
    uint256 public constant MAX_PRICE_AGE  = 90;      // seconds a Pyth price may be stale by

    address public owner;
    IERC20  public immutable marginToken;             // e.g. USDC on Arc Testnet
    IArchielLiquidityPool public immutable liquidityPool;
    IPyth   public immutable pyth;

    mapping(bytes32 => bool) public allowedFeedId;     // which Pyth price feed IDs may be traded

    enum Side { Long, Short }

    struct Position {
        address trader;
        bytes32 feedId;
        Side    side;
        uint256 margin;       // in marginToken units
        uint256 leverage;
        uint256 size;         // margin * leverage, in marginToken units
        uint256 entryPrice;   // scaled to PRICE_SCALE
        uint64  openedAt;
        bool    open;
    }

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public positionsByTrader;

    // ─────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────
    event PositionOpened(uint256 indexed id, address indexed trader, bytes32 feedId, Side side, uint256 margin, uint256 leverage, uint256 entryPrice);
    event PositionClosed(uint256 indexed id, address indexed trader, uint256 exitPrice, int256 pnl, uint256 payout);
    event PositionLiquidated(uint256 indexed id, address indexed trader, address indexed liquidator, uint256 exitPrice);
    event FeedAllowed(bytes32 indexed feedId, bool allowed);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor(address _marginToken, address _liquidityPool, address _pyth) {
        owner = msg.sender;
        marginToken   = IERC20(_marginToken);
        liquidityPool = IArchielLiquidityPool(_liquidityPool);
        pyth          = IPyth(_pyth);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Owner config
    // ─────────────────────────────────────────────────────────────────

    function setFeedAllowed(bytes32 feedId, bool allowed) external onlyOwner {
        allowedFeedId[feedId] = allowed;
        emit FeedAllowed(feedId, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────

    /// @notice All position IDs ever opened by a trader (open or closed).
    function getTraderPositionIds(address trader) external view returns (uint256[] memory) {
        return positionsByTrader[trader];
    }

    /// @notice Unrealized PnL for an open position at a given fresh price,
    ///         WITHOUT spending a Pyth update (for read-only UI display
    ///         using a price the frontend already fetched off-chain).
    function previewPnl(uint256 id, uint256 currentPrice)
        external view
        returns (int256 pnl, uint256 payout, uint256 loss)
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");
        return _settle(pos, currentPrice);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal: Pyth price read (with mandatory fresh update)
    // ─────────────────────────────────────────────────────────────────

    /// @dev Pushes the submitted Hermes update into Pyth, then reads the
    ///      resulting price for `feedId`, scaled to PRICE_SCALE (1e18).
    function _updateAndGetPrice(bytes32 feedId, bytes[] calldata priceUpdateData)
        internal returns (uint256 scaledPrice)
    {
        require(allowedFeedId[feedId], "Feed not allowed");

        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "Insufficient Pyth update fee");
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        PythPrice memory p = pyth.getPriceNoOlderThan(feedId, MAX_PRICE_AGE);
        require(p.price > 0, "Invalid price");

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

    // ─────────────────────────────────────────────────────────────────
    //  Open position
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Open a leveraged position. Pulls `margin` of marginToken from
     *         the caller and records entry price from a fresh Pyth update.
     *
     * @param feedId            Pyth price feed ID for the asset being traded
     * @param isLong             true = long, false = short
     * @param margin             Margin to post, in marginToken units
     * @param leverage           1–MAX_LEVERAGE
     * @param priceUpdateData    Hermes price-update bytes for feedId
     */
    function openPosition(
        bytes32 feedId,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant returns (uint256 id) {
        require(margin > 0, "Zero margin");
        require(leverage >= 1 && leverage <= MAX_LEVERAGE, "Bad leverage");

        uint256 entryPrice = _updateAndGetPrice(feedId, priceUpdateData);

        require(marginToken.transferFrom(msg.sender, address(this), margin), "Margin transfer failed");

        id = nextPositionId++;
        positions[id] = Position({
            trader:     msg.sender,
            feedId:     feedId,
            side:       isLong ? Side.Long : Side.Short,
            margin:     margin,
            leverage:   leverage,
            size:       margin * leverage,
            entryPrice: entryPrice,
            openedAt:   uint64(block.timestamp),
            open:       true
        });
        positionsByTrader[msg.sender].push(id);

        emit PositionOpened(id, msg.sender, feedId, positions[id].side, margin, leverage, entryPrice);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Close position
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Close an open position at the current Pyth price. Pays
     *         margin + PnL back to the trader (capped at 0 on the downside —
     *         a trader can never owe more than their posted margin).
     */
    function closePosition(uint256 id, bytes[] calldata priceUpdateData)
        external payable nonReentrant
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");
        require(pos.trader == msg.sender, "Not position owner");

        uint256 exitPrice = _updateAndGetPrice(pos.feedId, priceUpdateData);
        pos.open = false;

        (int256 pnl, uint256 payout, uint256 loss) = _settle(pos, exitPrice);
        _settlePayout(pos.trader, pos.margin, payout, loss);

        emit PositionClosed(id, msg.sender, exitPrice, pnl, payout);
    }

    /**
     * @notice Liquidate a position whose loss has reached or exceeded its
     *         margin. Callable by anyone (no liquidator reward in this v1 —
     *         keepers should be run by the protocol operator).
     */
    function liquidate(uint256 id, bytes[] calldata priceUpdateData)
        external payable nonReentrant
    {
        Position storage pos = positions[id];
        require(pos.open, "Not open");

        uint256 exitPrice = _updateAndGetPrice(pos.feedId, priceUpdateData);
        (, , uint256 loss) = _settle(pos, exitPrice);
        require(loss >= pos.margin, "Not liquidatable yet");

        pos.open = false;
        _settlePayout(pos.trader, pos.margin, 0, pos.margin);

        emit PositionLiquidated(id, pos.trader, msg.sender, exitPrice);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal settlement helpers (kept tiny to avoid stack-too-deep)
    // ─────────────────────────────────────────────────────────────────

    /// @dev Pure PnL math — no state changes, no token transfers.
    function _settle(Position storage pos, uint256 exitPrice)
        internal view
        returns (int256 pnl, uint256 payout, uint256 loss)
    {
        int256 priceDiff = int256(exitPrice) - int256(pos.entryPrice);
        if (pos.side == Side.Short) priceDiff = -priceDiff;

        pnl = (int256(pos.size) * priceDiff) / int256(pos.entryPrice);

        if (pnl >= 0) {
            payout = pos.margin + uint256(pnl);
            loss   = 0;
        } else {
            uint256 absPnl = uint256(-pnl);
            loss   = absPnl >= pos.margin ? pos.margin : absPnl;
            payout = pos.margin - loss;
        }
    }

    /**
     * @dev Moves real tokens to settle a closed/liquidated position.
     *      `originalMargin` is already held by this contract (pulled in at
     *      openPosition time). Two cases:
     *        - Trader lost money (loss > 0): forward the lost amount into
     *          the liquidity pool's futures counterparty reserve, then pay
     *          the trader whatever margin remains (payout = margin - loss).
     *        - Trader made a profit (payout > originalMargin): pay the
     *          trader their full original margin from this contract's own
     *          balance, then pull the extra profit from the liquidity
     *          pool's futures reserve and forward it too.
     */
    function _settlePayout(address trader, uint256 originalMargin, uint256 payout, uint256 loss) internal {
        if (loss > 0) {
            marginToken.approve(address(liquidityPool), loss);
            liquidityPool.receiveFromFutures(address(marginToken), loss);
        }

        uint256 fromOwnBalance = payout <= originalMargin ? payout : originalMargin;
        uint256 fromPoolProfit = payout - fromOwnBalance;

        if (fromOwnBalance > 0) {
            require(marginToken.transfer(trader, fromOwnBalance), "Payout transfer failed");
        }
        if (fromPoolProfit > 0) {
            liquidityPool.payoutToTrader(address(marginToken), trader, fromPoolProfit);
        }
    }
}
