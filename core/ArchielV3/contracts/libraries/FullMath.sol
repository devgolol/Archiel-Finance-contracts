// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FullMath
/// @notice Original implementation for Archiel V3 — full precision multiply-divide
/// without intermediate overflow, using 512-bit intermediate representation.
library FullMath {
    error FM_DivByZero();
    error FM_Overflow();

    /// @notice Computes floor(a * b / denominator) with full 512-bit precision.
    /// Reverts if the result overflows a uint256 or if denominator == 0.
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                if (denominator == 0) revert FM_DivByZero();
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            if (denominator <= prod1) revert FM_Overflow();

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
            return result;
        }
    }

    /// @notice Computes ceil(a * b / denominator).
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        unchecked {
            if (mulmod(a, b, denominator) > 0) {
                if (result >= type(uint256).max) revert FM_Overflow();
                result++;
            }
        }
    }
}
