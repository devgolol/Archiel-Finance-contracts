// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./FullMath.sol";

/// @title SqrtPriceMath
/// @notice Archiel original implementation of the core concentrated-liquidity
/// swap math: given liquidity and a sqrt price, compute token deltas and the
/// resulting sqrt price after adding/removing a given amount of token0/token1.
library SqrtPriceMath {
    error SPM_BadInput();
    error SPM_BadOutput();
    error SPM_Amount0TooLarge();
    error SPM_Amount1TooLarge();
    error SPM_ZeroRatio();

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function getNextSqrtPriceFromInput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        if (sqrtPX96 == 0 || liquidity == 0) revert SPM_BadInput();
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    function getNextSqrtPriceFromOutput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        if (sqrtPX96 == 0 || liquidity == 0) revert SPM_BadOutput();
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    function getNextSqrtPriceFromAmount0RoundingUp(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << 96;

        if (add) {
            uint256 denominator = numerator1 + amount * sqrtPX96;
            if (denominator >= numerator1) {
                return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
            }
            return uint160(FullMath.mulDivRoundingUp(numerator1, 1, (numerator1 / sqrtPX96) + amount));
        } else {
            uint256 product = amount * sqrtPX96;
            if (numerator1 <= product) revert SPM_Amount0TooLarge();
            uint256 denominator = numerator1 - product;
            return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
        }
    }

    function getNextSqrtPriceFromAmount1RoundingDown(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        if (add) {
            uint256 quotient = (amount << 96) / liquidity;
            return uint160(uint256(sqrtPX96) + quotient);
        } else {
            uint256 quotient = FullMath.mulDivRoundingUp(amount, Q96, liquidity);
            if (sqrtPX96 <= quotient) revert SPM_Amount1TooLarge();
            return uint160(uint256(sqrtPX96) - quotient);
        }
    }

    /// @notice token0 delta between two sqrt prices for a given liquidity
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 numerator1 = uint256(liquidity) << 96;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;
        if (sqrtRatioAX96 == 0) revert SPM_ZeroRatio();

        if (roundUp) {
            amount0 = FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96),
                1,
                sqrtRatioAX96
            );
        } else {
            amount0 = FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
        }
    }

    /// @notice token1 delta between two sqrt prices for a given liquidity
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 diff = sqrtRatioBX96 - sqrtRatioAX96;
        amount1 = roundUp
            ? FullMath.mulDivRoundingUp(liquidity, diff, Q96)
            : FullMath.mulDiv(liquidity, diff, Q96);
    }
}
