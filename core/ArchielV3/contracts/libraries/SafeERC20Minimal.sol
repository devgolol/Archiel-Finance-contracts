// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IERC20Minimal.sol";

/// @title SafeERC20Minimal
/// @notice Archiel original — wraps transfer()/transferFrom() so a
/// non-standard token can't silently fail. Plain IERC20Minimal calls only
/// catch a revert; some real-world tokens (older USDT-style contracts, some
/// non-compliant tokens found on testnets) return `false` instead of
/// reverting on failure, or return no data at all instead of a bool. This
/// treats "call reverted", "call returned false", and "call succeeded but
/// decodes to false" all as failures, while still accepting tokens that
/// return no data (a valid pattern per EIP-20) as success.
library SafeERC20Minimal {
    error SafeERC20_NotAContract();
    error SafeERC20_CallFailed();
    error SafeERC20_OpReturnedFalse();

    function safeTransfer(address token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, value));
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, value));
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        if (token.code.length == 0) revert SafeERC20_NotAContract();
        (bool success, bytes memory returndata) = token.call(data);
        if (!success) revert SafeERC20_CallFailed();
        if (returndata.length > 0) {
            if (!abi.decode(returndata, (bool))) revert SafeERC20_OpReturnedFalse();
        }
        // returndata.length == 0 with success == true is accepted — some
        // compliant tokens (e.g. older USDT-style contracts) return no data.
    }
}
