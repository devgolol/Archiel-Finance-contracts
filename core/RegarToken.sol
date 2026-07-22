// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RegarToken is ERC20 {
    constructor() ERC20("REGAR Token", "REGAR") {
        // Ini akan mencetak 100 Juta Token REGAR
        _mint(msg.sender, 100000000 * 10 ** decimals());
    }
}