// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./libraries/NFTDescriptor.sol";

/// @title ArchielV3NFTDescriptor
/// @notice Archiel original — deployed SEPARATELY from
/// ArchielV3PositionManager purely to keep bytecode size down. The animated
/// on-chain SVG generation (NFTSVG/NFTDescriptor/Base64/StringsMinimal) is a
/// meaningful chunk of code on its own; inlining it into PositionManager
/// pushed that contract past the 24,576-byte EIP-170 limit. Splitting it out
/// into its own contract, called via an external view call from
/// PositionManager.tokenURI(), is the same pattern Uniswap V3 itself uses
/// (NonfungibleTokenPositionDescriptor is a separate contract from
/// NonfungiblePositionManager for exactly this reason).
contract ArchielV3NFTDescriptor {
    function tokenURI(
        uint256 tokenId,
        string calldata token0Symbol,
        string calldata token1Symbol,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        address pool,
        bool inRange
    ) external pure returns (string memory) {
        return NFTDescriptor.constructTokenURI(
            NFTDescriptor.ConstructParams({
                tokenId: tokenId,
                token0Symbol: token0Symbol,
                token1Symbol: token1Symbol,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                pool: pool,
                inRange: inRange
            })
        );
    }
}
