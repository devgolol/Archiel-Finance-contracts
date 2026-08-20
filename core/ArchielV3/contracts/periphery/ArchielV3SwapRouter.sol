// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IArchielV3Pool.sol";
import "../interfaces/IERC20Minimal.sol";
import "../core/ArchielV3Factory.sol";
import "../libraries/SafeERC20Minimal.sol";
import "./libraries/Path.sol";
import "./libraries/Multicall.sol";

/// @title ArchielV3SwapRouter
/// @notice User-facing router that pulls tokens from the caller via
/// transferFrom during the pool's swap callback, so users only need to
/// approve the router (not each pool) before swapping. Supports single-hop
/// and multi-hop (path-encoded) swaps, exact-input and exact-output, plus
/// Multicall for batching several swaps/actions in one transaction.
contract ArchielV3SwapRouter is IArchielV3SwapCallback, Multicall {
    using Path for bytes;
    using SafeERC20Minimal for address;

    error AV3R_Expired();
    error AV3R_PoolNotFound();
    error AV3R_InsufficientOutput();
    error AV3R_ExcessiveInput();
    error AV3R_NoSwapExecuted();
    error AV3R_ZeroLiquiditySwap();
    error AV3R_UnauthorizedCallback();

    ArchielV3Factory public immutable factory;

    uint160 private constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 private constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path; // (tokenIn, fee, token, fee, ..., tokenOut), forward order
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path; // (tokenOut, fee, token, fee, ..., tokenIn), REVERSED order
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert AV3R_Expired();
        _;
    }

    constructor(address _factory) {
        factory = ArchielV3Factory(_factory);
    }

    function _getPool(address tokenA, address tokenB, uint24 fee) private view returns (IArchielV3Pool) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pool = factory.getPool(t0, t1, fee);
        if (pool == address(0)) revert AV3R_PoolNotFound();
        return IArchielV3Pool(pool);
    }

    function _pay(address token, address payer, address recipient, uint256 value) private {
        token.safeTransferFrom(payer, recipient, value);
    }

    // ---------------------------------------------------------------------
    // Exact input
    // ---------------------------------------------------------------------

    function _exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = _getPool(tokenIn, tokenOut, fee).swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE)
                : sqrtPriceLimitX96,
            abi.encode(data)
        );
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @notice Single-hop: swaps exactly `amountIn` of tokenIn for as much tokenOut as possible.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        amountOut = _exactInputInternal(
            params.amountIn,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut),
                payer: msg.sender
            })
        );
        if (amountOut < params.amountOutMinimum) revert AV3R_InsufficientOutput();
    }

    /// @notice Multi-hop: swaps exactly `amountIn` along an encoded route of pools.
    function exactInput(ExactInputParams memory params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        address payer = msg.sender;

        while (true) {
            bool hasMultiplePools = params.path.hasMultiplePools();

            params.amountIn = _exactInputInternal(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient,
                0,
                SwapCallbackData({path: params.path.getFirstPool(), payer: payer})
            );

            if (hasMultiplePools) {
                payer = address(this);
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }

        if (amountOut < params.amountOutMinimum) revert AV3R_InsufficientOutput();
    }

    // ---------------------------------------------------------------------
    // Exact output
    // ---------------------------------------------------------------------

    function _exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        (address tokenOut, address tokenIn, uint24 fee) = data.path.decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0Delta, int256 amount1Delta) = _getPool(tokenIn, tokenOut, fee).swap(
            recipient,
            zeroForOne,
            -int256(amountOut),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE)
                : sqrtPriceLimitX96,
            abi.encode(data)
        );
        amountIn = zeroForOne ? uint256(amount0Delta) : uint256(amount1Delta);
    }

    /// @notice Single-hop: swaps as little tokenIn as possible for exactly `amountOut` of tokenOut.
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        amountIn = _exactOutputInternal(
            params.amountOut,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn),
                payer: msg.sender
            })
        );
        if (amountIn > params.amountInMaximum) revert AV3R_ExcessiveInput();
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    /// @notice Multi-hop: swaps as little of the input token as possible for exactly
    /// `amountOut` along an encoded route. `params.path` must be REVERSED
    /// (tokenOut first) since exact-output resolution walks backward from the output.
    function exactOutput(ExactOutputParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        _exactOutputInternal(
            params.amountOut,
            params.recipient,
            0,
            SwapCallbackData({path: params.path, payer: msg.sender})
        );

        amountIn = amountInCached;
        if (amountIn > params.amountInMaximum) revert AV3R_ExcessiveInput();
        if (amountIn == DEFAULT_AMOUNT_IN_CACHED) revert AV3R_NoSwapExecuted();
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    // ---------------------------------------------------------------------
    // Callback
    // ---------------------------------------------------------------------

    function archielV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        if (amount0Delta <= 0 && amount1Delta <= 0) revert AV3R_ZeroLiquiditySwap();
        SwapCallbackData memory cbData = abi.decode(data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = cbData.path.decodeFirstPool();

        if (msg.sender != address(_getPool(tokenIn, tokenOut, fee))) revert AV3R_UnauthorizedCallback();

        (bool isExactInput, uint256 amountToPay) = amount0Delta > 0
            ? (tokenIn < tokenOut, uint256(amount0Delta))
            : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            _pay(tokenIn, cbData.payer, msg.sender, amountToPay);
        } else if (cbData.path.hasMultiplePools()) {
            cbData.path = cbData.path.skipToken();
            _exactOutputInternal(amountToPay, msg.sender, 0, cbData);
        } else {
            amountInCached = amountToPay;
            // In a reversed exact-output path, tokenOut here is the true input token
            _pay(tokenOut, cbData.payer, msg.sender, amountToPay);
        }
    }
}
