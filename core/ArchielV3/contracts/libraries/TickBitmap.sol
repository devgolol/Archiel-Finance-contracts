// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TickBitmap
/// @notice Archiel original implementation — packs initialized-tick flags
/// into 256-bit words so the pool can skip empty ticks during a swap
/// instead of stepping one-by-one.
library TickBitmap {
    error TB_NotAligned();
    error TB_Zero();

    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick % 256 < 0 ? tick % 256 + 256 : tick % 256));
    }

    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        if (tick % tickSpacing != 0) revert TB_NotAligned();
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        self[wordPos] ^= (1 << bitPos);
    }

    /// @notice Finds the next initialized tick within one word of the given tick
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;

        if (lte) {
            (int16 wordPos, uint8 bitPos) = position(compressed);
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = self[wordPos] & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = self[wordPos] & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed + 1 + int24(uint24(leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + 1 + int24(uint24(255 - bitPos))) * tickSpacing;
        }
    }

    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert TB_Zero();
        unchecked {
            if (x >= 2**128) { x >>= 128; r += 128; }
            if (x >= 2**64) { x >>= 64; r += 64; }
            if (x >= 2**32) { x >>= 32; r += 32; }
            if (x >= 2**16) { x >>= 16; r += 16; }
            if (x >= 2**8) { x >>= 8; r += 8; }
            if (x >= 2**4) { x >>= 4; r += 4; }
            if (x >= 2**2) { x >>= 2; r += 2; }
            if (x >= 2**1) { r += 1; }
        }
    }

    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert TB_Zero();
        r = 255;
        unchecked {
            if (x & type(uint128).max > 0) { r -= 128; } else { x >>= 128; }
            if (x & type(uint64).max > 0) { r -= 64; } else { x >>= 64; }
            if (x & type(uint32).max > 0) { r -= 32; } else { x >>= 32; }
            if (x & type(uint16).max > 0) { r -= 16; } else { x >>= 16; }
            if (x & type(uint8).max > 0) { r -= 8; } else { x >>= 8; }
            if (x & 0xf > 0) { r -= 4; } else { x >>= 4; }
            if (x & 0x3 > 0) { r -= 2; } else { x >>= 2; }
            if (x & 0x1 > 0) { r -= 1; }
        }
    }
}
