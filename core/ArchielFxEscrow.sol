// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts@5.6.1/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.6.1/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts@5.6.1/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts@5.6.1/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@5.6.1/access/Ownable.sol";
import "@openzeppelin/contracts@5.6.1/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts@5.6.1/utils/Pausable.sol";

// ─────────────────────────────────────────────────────────────
// Minimal Pyth interface (avoids pulling in the full pyth-sdk-solidity
// package; matches the on-chain IPyth ABI used by Pyth Core contracts).
// ─────────────────────────────────────────────────────────────
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
}

/// @title ArchielFxEscrow
/// @notice "Mock RFQ" style FX swap between two Pyth-priced stablecoins (e.g. USDC <-> EURC)
///         on Arc Testnet. This is NOT Circle StableFX — it is Archiel Finance's own
///         on-chain escrow that prices swaps using live Pyth oracle data instead of an
///         internal AMM curve. Liquidity is seeded by the admin (owner), not by an
///         automated market maker or external RFQ liquidity providers.
contract ArchielFxEscrow is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IPyth public immutable pyth;

    /// @notice Pyth price feed ID (vs USD) for each supported token.
    mapping(address => bytes32) public priceFeedId;

    /// @notice Whether a token is currently enabled for swapping.
    mapping(address => bool) public supportedToken;

    /// @notice True if the Pyth feed for this token quotes USD/TOKEN instead of
    ///         TOKEN/USD (e.g. Pyth's "USD/JPY" feed gives JPY per 1 USD, the
    ///         opposite direction of "EUR/USD" which gives USD per 1 EUR).
    ///         When true, the raw Pyth price is inverted (1/price) before use.
    mapping(address => bool) public isInvertedFeed;

    /// @notice Max age (seconds) a Pyth price is allowed to be before it's rejected as stale.
    uint256 public maxPriceAge = 60;

    /// @notice Swap fee in basis points (e.g. 30 = 0.30%). Taken from amountOut.
    uint256 public feeBps = 0;
    uint256 public constant MAX_FEE_BPS = 200; // hard cap 2%, sanity guard

    address public feeRecipient;

    event TokenConfigured(address indexed token, bytes32 feedId, bool inverted, bool supported);
    event MaxPriceAgeUpdated(uint256 newMaxAge);
    event FeeUpdated(uint256 newFeeBps, address newRecipient);
    event LiquidityDeposited(address indexed token, address indexed from, uint256 amount);
    event LiquidityWithdrawn(address indexed token, address indexed to, uint256 amount);
    event Swap(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        int64 priceIn,
        int64 priceOut
    );

    constructor(address pythContract, address initialOwner) Ownable(initialOwner) {
        require(pythContract != address(0), "pyth=0");
        pyth = IPyth(pythContract);
        feeRecipient = initialOwner;
    }

    // ─────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────

    /// @notice Enable/configure a token for swapping and set its Pyth feed ID (vs USD).
    /// @param inverted Set true if the Pyth feed quotes USD/TOKEN rather than TOKEN/USD
    ///        (e.g. Pyth's "USD/JPY" feed for a JPYC token). Check the feed's quote
    ///        direction on pyth.network/price-feeds before setting this.
    function setPriceFeedId(address token, bytes32 feedId, bool inverted, bool enabled) external onlyOwner {
        require(token != address(0), "token=0");
        require(feedId != bytes32(0) || !enabled, "feedId=0");
        priceFeedId[token] = feedId;
        isInvertedFeed[token] = inverted;
        supportedToken[token] = enabled;
        emit TokenConfigured(token, feedId, inverted, enabled);
    }

    function setMaxPriceAge(uint256 newMaxAge) external onlyOwner {
        require(newMaxAge > 0 && newMaxAge <= 3600, "bad range");
        maxPriceAge = newMaxAge;
        emit MaxPriceAgeUpdated(newMaxAge);
    }

    function setFee(uint256 newFeeBps, address newRecipient) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        require(newRecipient != address(0), "recipient=0");
        feeBps = newFeeBps;
        feeRecipient = newRecipient;
        emit FeeUpdated(newFeeBps, newRecipient);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Admin seeds swap liquidity for a token (must approve first).
    function depositLiquidity(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "amount=0");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityDeposited(token, msg.sender, amount);
    }

    /// @notice Admin withdraws idle liquidity for a token.
    function withdrawLiquidity(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "to=0");
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(token, to, amount);
    }

    // ─────────────────────────────────────────────────────────
    // Swap
    // ─────────────────────────────────────────────────────────

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut`, priced off live Pyth data.
    /// @param priceUpdateData Hermes update data (hex-encoded VAAs) for both tokenIn and
    ///        tokenOut feeds, fetched off-chain from https://hermes.pyth.network before
    ///        calling this function. Pass msg.value >= pyth.getUpdateFee(priceUpdateData).
    /// @dev Caller must have already approved this contract for `amountIn` of tokenIn.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        amountOut = _executeSwap(tokenIn, tokenOut, amountIn, minAmountOut, priceUpdateData);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        _settle(tokenOut, amountOut);
    }

    /// @notice Same as `swap`, but uses an EIP-2612 `permit` signature instead of a
    ///         separate prior `approve()` transaction (gas-saving / better UX).
    function permitSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes[] calldata priceUpdateData,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        IERC20Permit(tokenIn).permit(msg.sender, address(this), amountIn, permitDeadline, v, r, s);
        amountOut = _executeSwap(tokenIn, tokenOut, amountIn, minAmountOut, priceUpdateData);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        _settle(tokenOut, amountOut);
    }

    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes[] calldata priceUpdateData
    ) internal returns (uint256 amountOut) {
        require(supportedToken[tokenIn] && supportedToken[tokenOut], "unsupported token");
        require(tokenIn != tokenOut, "same token");
        require(amountIn > 0, "amountIn=0");

        // Pay for and apply the price update, then refund any excess ETH sent.
        if (priceUpdateData.length > 0) {
            uint256 fee = pyth.getUpdateFee(priceUpdateData);
            require(msg.value >= fee, "insufficient update fee");
            pyth.updatePriceFeeds{value: fee}(priceUpdateData);
            if (msg.value > fee) {
                (bool ok, ) = msg.sender.call{value: msg.value - fee}("");
                require(ok, "refund failed");
            }
        } else if (msg.value > 0) {
            (bool ok, ) = msg.sender.call{value: msg.value}("");
            require(ok, "refund failed");
        }

        (uint256 grossOut, int64 priceIn, int64 priceOut) = _quoteGross(tokenIn, tokenOut, amountIn);

        uint256 feeAmount = (grossOut * feeBps) / 10_000;
        amountOut = grossOut - feeAmount;

        require(amountOut >= minAmountOut, "slippage: amountOut too low");
        require(IERC20(tokenOut).balanceOf(address(this)) >= amountOut + feeAmount, "insufficient escrow liquidity");

        if (feeAmount > 0) {
            IERC20(tokenOut).safeTransfer(feeRecipient, feeAmount);
        }

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, feeAmount, priceIn, priceOut);
    }

    /// @dev Fetches fresh Pyth prices for both legs and returns the gross (pre-fee)
    ///      converted amount, plus the raw prices used (for the Swap event). Isolating
    ///      this in its own function keeps the two `Price memory` structs and their
    ///      fields off `_executeSwap`'s stack, avoiding "stack too deep".
    function _quoteGross(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 grossOut, int64 priceIn, int64 priceOut)
    {
        IPyth.Price memory pIn = pyth.getPriceNoOlderThan(priceFeedId[tokenIn], maxPriceAge);
        IPyth.Price memory pOut = pyth.getPriceNoOlderThan(priceFeedId[tokenOut], maxPriceAge);
        require(pIn.price > 0 && pOut.price > 0, "bad price");

        grossOut = _convert(
            amountIn,
            IERC20Metadata(tokenIn).decimals(),
            pIn,
            isInvertedFeed[tokenIn],
            IERC20Metadata(tokenOut).decimals(),
            pOut,
            isInvertedFeed[tokenOut]
        );
        priceIn = pIn.price;
        priceOut = pOut.price;
    }

    function _settle(address tokenOut, uint256 amountOut) internal {
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    // ─────────────────────────────────────────────────────────
    // Pricing math
    // ─────────────────────────────────────────────────────────

    /// @dev Converts amountIn (tokenIn's native decimals) to tokenOut's native decimals,
    ///      bridging through USD via the two Pyth prices. All intermediate math is done
    ///      in 1e18 fixed point to avoid precision loss.
    function _convert(
        uint256 amountIn,
        uint8 decimalsIn,
        IPyth.Price memory pIn,
        bool invertedIn,
        uint8 decimalsOut,
        IPyth.Price memory pOut,
        bool invertedOut
    ) internal pure returns (uint256) {
        uint256 amountIn18 = _to18(amountIn, decimalsIn);
        uint256 priceIn18 = _priceTo18(pIn, invertedIn);
        uint256 priceOut18 = _priceTo18(pOut, invertedOut);

        uint256 usdValue18 = (amountIn18 * priceIn18) / 1e18;
        uint256 amountOut18 = (usdValue18 * 1e18) / priceOut18;

        return _from18(amountOut18, decimalsOut);
    }

    function _to18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    function _from18(uint256 amount18, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount18;
        if (decimals < 18) return amount18 / (10 ** (18 - decimals));
        return amount18 * (10 ** (decimals - 18));
    }

    /// @dev Normalizes a Pyth Price (price * 10^expo) to an 18-decimal fixed-point uint,
    ///      representing "USD per 1 unit of token". If `inverted` is true, the raw feed
    ///      instead quotes "TOKEN per 1 USD" (e.g. Pyth's USD/JPY feed), so the result
    ///      is flipped (1 / rawPrice18) to get back to "USD per 1 unit of token".
    function _priceTo18(IPyth.Price memory p, bool inverted) internal pure returns (uint256) {
        require(p.price > 0, "non-positive price");
        uint256 price = uint256(uint64(p.price));
        int32 targetExpo = 18 + p.expo; // p.expo is typically negative (e.g. -8)
        uint256 raw18;
        if (targetExpo >= 0) {
            raw18 = price * (10 ** uint32(targetExpo));
        } else {
            raw18 = price / (10 ** uint32(-targetExpo));
        }
        if (!inverted) {
            return raw18;
        }
        // Flip: (1e18 * 1e18) / raw18, keeping 1e18 fixed-point precision.
        return (1e18 * 1e18) / raw18;
    }

    // ─────────────────────────────────────────────────────────
    // Views (for frontend UI preview — may reflect a stale price if
    // nobody has recently paid to push a Pyth update on-chain; prefer
    // fetching a live quote from Hermes directly in the UI for display,
    // and reserve this on-chain quote for pre-flight slippage checks).
    // ─────────────────────────────────────────────────────────

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOutAfterFee) {
        require(supportedToken[tokenIn] && supportedToken[tokenOut], "unsupported token");
        IPyth.Price memory pIn = pyth.getPriceUnsafe(priceFeedId[tokenIn]);
        IPyth.Price memory pOut = pyth.getPriceUnsafe(priceFeedId[tokenOut]);
        uint256 gross = _convert(
            amountIn,
            IERC20Metadata(tokenIn).decimals(),
            pIn,
            isInvertedFeed[tokenIn],
            IERC20Metadata(tokenOut).decimals(),
            pOut,
            isInvertedFeed[tokenOut]
        );
        uint256 fee = (gross * feeBps) / 10_000;
        return gross - fee;
    }

    // Allow the contract to receive ETH refunds cleanly.
    receive() external payable {}
}
