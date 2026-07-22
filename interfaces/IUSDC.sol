// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract ApproveUSDC {

    function approveMessenger(uint256 amount) external {
        IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)
            .approve(0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA, amount);
    }

    function checkBalance(address wallet) external view returns (uint256) {
        return IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)
            .balanceOf(wallet);
    }
}