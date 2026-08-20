// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Multicall
/// @notice Archiel original — lets callers batch multiple calls (e.g. swap +
/// unwrap, or mint + refund) into a single transaction via delegatecall.
abstract contract Multicall {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) {
                if (result.length > 0) {
                    assembly {
                        revert(add(result, 32), mload(result))
                    }
                } else {
                    revert("Multicall: call failed");
                }
            }
            results[i] = result;
        }
    }
}
