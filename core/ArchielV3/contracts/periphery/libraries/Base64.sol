// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Base64
/// @notice Archiel original base64 encoder for building on-chain tokenURI JSON/SVG.
library Base64 {
    bytes internal constant TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";

        uint256 len = data.length;
        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        bytes memory table = TABLE;

        uint256 i;
        uint256 j;
        for (i = 0; i + 3 <= len; i += 3) {
            (result[j], result[j + 1], result[j + 2], result[j + 3]) = _encode3(
                table, uint8(data[i]), uint8(data[i + 1]), uint8(data[i + 2])
            );
            j += 4;
        }

        uint256 remainder = len - i;
        if (remainder == 1) {
            (result[j], result[j + 1], , ) = _encode3(table, uint8(data[i]), 0, 0);
            result[j + 2] = "=";
            result[j + 3] = "=";
        } else if (remainder == 2) {
            (result[j], result[j + 1], result[j + 2], ) = _encode3(table, uint8(data[i]), uint8(data[i + 1]), 0);
            result[j + 3] = "=";
        }

        return string(result);
    }

    function _encode3(
        bytes memory table,
        uint8 b0,
        uint8 b1,
        uint8 b2
    ) private pure returns (bytes1, bytes1, bytes1, bytes1) {
        uint256 n = (uint256(b0) << 16) | (uint256(b1) << 8) | uint256(b2);
        return (
            table[(n >> 18) & 0x3F],
            table[(n >> 12) & 0x3F],
            table[(n >> 6) & 0x3F],
            table[n & 0x3F]
        );
    }
}
