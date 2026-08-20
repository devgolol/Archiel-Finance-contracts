// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IArchielV3Pool.sol";
import "../core/ArchielV3Factory.sol";

/// @title ArchielV3Quoter
/// @notice Read-only price quoting for the frontend. Since concentrated
/// liquidity swaps cross ticks in a path-dependent way, quoting is done by
/// actually running the swap logic and reverting with the result — the
/// revert is caught off-chain (eth_call) so no state is ever changed.
contract ArchielV3Quoter is IArchielV3SwapCallback {
    ArchielV3Factory public immutable factory;

    error AV3Q_PoolNotFound();
    error AV3Q_UnexpectedSuccess();
    error AV3Q_SwapReverted();

    constructor(address _factory) {
        factory = ArchielV3Factory(_factory);
    }

    function _getPool(address tokenA, address tokenB, uint24 fee) private view returns (IArchielV3Pool) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pool = factory.getPool(token0, token1, fee);
        if (pool == address(0)) revert AV3Q_PoolNotFound();
        return IArchielV3Pool(pool);
    }

    /// @notice Simulates exactInputSingle and returns the resulting output amount.
    /// Intended to be called via eth_call (staticcall) from the frontend — the
    /// underlying swap always reverts so no tokens are ever moved on-chain.
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter) {
        bool zeroForOne = tokenIn < tokenOut;
        IArchielV3Pool pool = _getPool(tokenIn, tokenOut, fee);

        try pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341)
                : sqrtPriceLimitX96,
            abi.encode(zeroForOne)
        ) {
            // swap() only reverts inside the callback below, so this path is unreachable
            revert AV3Q_UnexpectedSuccess();
        } catch (bytes memory reason) {
            return _parseRevertReason(reason);
        }
    }

    function archielV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external pure override {
        bool zeroForOne = abi.decode(data, (bool));
        // Encode the quote into the revert reason and abort before any token transfer occurs
        int256 amountOut = zeroForOne ? -amount1Delta : -amount0Delta;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amountOut)
            revert(ptr, 32)
        }
    }

    function _parseRevertReason(bytes memory reason) private pure returns (uint256 amountOut, uint160, int24) {
        if (reason.length != 32) {
            if (reason.length < 68) revert AV3Q_SwapReverted();
            assembly { reason := add(reason, 0x04) }
            revert(abi.decode(reason, (string)));
        }
        int256 out = abi.decode(reason, (int256));
        amountOut = uint256(out);
        // sqrtPriceX96After / tickAfter omitted from this lightweight path;
        // callers needing post-swap price should read pool.slot0() directly
        return (amountOut, 0, 0);
    }
}
