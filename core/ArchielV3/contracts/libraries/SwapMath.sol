// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./SqrtPriceMath.sol";
import "./FullMath.sol";

/// @title SwapMath
/// @notice Archiel original implementation computing the result of one swap
/// step confined between the current price and a target price (a tick
/// boundary or the user's limit), including the fee taken on that step.
library SwapMath {
    uint256 internal constant FEE_DENOMINATOR = 1_000_000; // fee is in hundredths of a bip

    struct StepResult {
        uint160 sqrtRatioNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (StepResult memory r) {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            uint256 amountRemainingLessFee = FullMath.mulDiv(
                uint256(amountRemaining),
                FEE_DENOMINATOR - feePips,
                FEE_DENOMINATOR
            );
            r.amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);

            if (amountRemainingLessFee >= r.amountIn) {
                r.sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                r.sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
            }
        } else {
            r.amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);

            uint256 wantOut = uint256(-amountRemaining);
            if (wantOut >= r.amountOut) {
                r.sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                r.sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    wantOut,
                    zeroForOne
                );
            }
        }

        bool max = sqrtRatioTargetX96 == r.sqrtRatioNextX96;

        if (zeroForOne) {
            r.amountIn = (max && exactIn)
                ? r.amountIn
                : SqrtPriceMath.getAmount0Delta(r.sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            r.amountOut = (max && !exactIn)
                ? r.amountOut
                : SqrtPriceMath.getAmount1Delta(r.sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            r.amountIn = (max && exactIn)
                ? r.amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, r.sqrtRatioNextX96, liquidity, true);
            r.amountOut = (max && !exactIn)
                ? r.amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, r.sqrtRatioNextX96, liquidity, false);
        }

        if (!exactIn && r.amountOut > uint256(-amountRemaining)) {
            r.amountOut = uint256(-amountRemaining);
        }

        if (exactIn && r.sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // consumed the full remaining amount within this step
            r.feeAmount = uint256(amountRemaining) - r.amountIn;
        } else {
            r.feeAmount = FullMath.mulDivRoundingUp(r.amountIn, feePips, FEE_DENOMINATOR - feePips);
        }
    }
}
