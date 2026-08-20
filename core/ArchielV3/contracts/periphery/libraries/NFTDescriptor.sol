// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base64.sol";
import "./NFTSVG.sol";
import "./StringsMinimal.sol";

/// @title NFTDescriptor
/// @notice Archiel original — assembles the on-chain tokenURI (base64 JSON
/// with an embedded base64 SVG image) for an ArchielV3 position NFT.
library NFTDescriptor {
    using StringsMinimal for uint256;

    struct ConstructParams {
        uint256 tokenId;
        string token0Symbol;
        string token1Symbol;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        address pool;
        bool inRange;
    }

    function constructTokenURI(ConstructParams memory params) internal pure returns (string memory) {
        string memory svg = NFTSVG.generateSVG(
            NFTSVG.SVGParams({
                tokenId: params.tokenId,
                token0Symbol: params.token0Symbol,
                token1Symbol: params.token1Symbol,
                fee: params.fee,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                pool: params.pool,
                inRange: params.inRange
            })
        );

        string memory image = string(
            abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svg)))
        );

        string memory name = string(
            abi.encodePacked(
                "Archiel V3 Position - ", params.token0Symbol, "/", params.token1Symbol,
                " #", params.tokenId.toString()
            )
        );

        string memory description = string(
            abi.encodePacked(
                "This NFT represents a concentrated liquidity position in an Archiel V3 ",
                params.token0Symbol, "-", params.token1Symbol,
                " pool on Arc Testnet. Owning this NFT lets you withdraw the underlying "
                "liquidity and any accrued fees. Trading pair fees may vary by pool."
            )
        );

        bytes memory json = abi.encodePacked(
            '{"name":"', name, '",',
            '"description":"', description, '",',
            '"image":"', image, '"}'
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }
}
