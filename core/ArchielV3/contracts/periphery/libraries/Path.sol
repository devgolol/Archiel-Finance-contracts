// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Path
/// @notice Archiel original — encodes a multi-hop swap route as tightly
/// packed (token, fee, token, fee, token, ...) bytes, so exactInput/
/// exactOutput can walk it one pool at a time.
library Path {
    uint256 private constant ADDR_SIZE = 20;
    uint256 private constant FEE_SIZE = 3;
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + FEE_SIZE;
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH = POP_OFFSET + NEXT_OFFSET;

    error Path_OutOfBounds();

    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    function numPools(bytes memory path) internal pure returns (uint256) {
        return (path.length - ADDR_SIZE) / NEXT_OFFSET;
    }

    function decodeFirstPool(bytes memory path)
        internal
        pure
        returns (address tokenA, address tokenB, uint24 fee)
    {
        tokenA = toAddress(path, 0);
        fee = toUint24(path, ADDR_SIZE);
        tokenB = toAddress(path, NEXT_OFFSET);
    }

    function getFirstPool(bytes memory path) internal pure returns (bytes memory) {
        return slice(path, 0, POP_OFFSET);
    }

    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        return slice(path, NEXT_OFFSET, path.length - NEXT_OFFSET);
    }

    function toAddress(bytes memory data, uint256 start) internal pure returns (address result) {
        if (data.length < start + ADDR_SIZE) revert Path_OutOfBounds();
        assembly {
            result := mload(add(add(data, 20), start))
        }
    }

    function toUint24(bytes memory data, uint256 start) internal pure returns (uint24 result) {
        if (data.length < start + FEE_SIZE) revert Path_OutOfBounds();
        assembly {
            result := mload(add(add(data, 3), start))
        }
    }

    function slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory) {
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = data[start + i];
        }
        return result;
    }
}
