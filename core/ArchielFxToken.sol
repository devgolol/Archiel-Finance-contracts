// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts@5.6.1/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@5.6.1/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts@5.6.1/access/Ownable.sol";

/// @title ArchielFxToken
/// @notice Generic mintable ERC-20 for Archiel Finance testnet demo assets
///         (e.g. GBPC, JPYC, AUDC, sXAU, sXAG). NOT backed by any real-world
///         asset or fiat reserve — for Arc Testnet demo/UX purposes only.
///         Includes EIP-2612 permit so it's compatible with FxEscrow.permitSwap().
contract ArchielFxToken is ERC20, ERC20Permit, Ownable {
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address initialOwner
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(initialOwner) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Owner-only faucet/mint, e.g. to seed FxEscrow liquidity or
    ///         to top up a user's testnet balance for demo purposes.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Optional: lets anyone self-mint a small amount for testing,
    ///         mirroring a public faucet. Disabled by default; owner can enable.
    bool public publicFaucetEnabled;
    uint256 public publicFaucetAmount = 1000 * 10 ** 18; // adjusted at mint time by decimals below
    mapping(address => uint256) public lastFaucetClaim;
    uint256 public faucetCooldown = 1 days;

    function setPublicFaucet(bool enabled, uint256 amountPerClaim, uint256 cooldownSeconds) external onlyOwner {
        publicFaucetEnabled = enabled;
        publicFaucetAmount = amountPerClaim;
        faucetCooldown = cooldownSeconds;
    }

    function claimFaucet() external {
        require(publicFaucetEnabled, "faucet disabled");
        require(block.timestamp >= lastFaucetClaim[msg.sender] + faucetCooldown, "cooldown active");
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, publicFaucetAmount);
    }
}
