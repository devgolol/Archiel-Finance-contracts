// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./StringsMinimal.sol";

/// @title NFTSVG
/// @notice Archiel original — generates an animated on-chain SVG card for a
/// concentrated-liquidity position. Colors are deterministically derived from
/// the pool address so every pair gets a stable, unique look. Pure SVG/SMIL
/// animation — no JS, renders in any SVG-capable viewer/marketplace.
library NFTSVG {
    using StringsMinimal for uint256;
    using StringsMinimal for int256;

    struct SVGParams {
        uint256 tokenId;
        string token0Symbol;
        string token1Symbol;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        address pool;
        bool inRange;
    }

    function generateSVG(SVGParams memory params) internal pure returns (string memory) {
        (uint256 hueA, uint256 hueB) = _colorsFromPool(params.pool);

        return string(
            abi.encodePacked(
                _svgHeader(hueA, hueB),
                _svgOrbit(hueA, hueB, params.inRange),
                _svgWave(hueA),
                _svgText(params),
                "</svg>"
            )
        );
    }

    function _colorsFromPool(address pool) private pure returns (uint256 hueA, uint256 hueB) {
        uint256 seed = uint256(uint160(pool));
        hueA = seed % 360;
        hueB = (hueA + 120 + (seed >> 8) % 80) % 360;
    }

    function _svgHeader(uint256 hueA, uint256 hueB) private pure returns (string memory) {
        return string(abi.encodePacked(_svgHeaderDefs(hueA, hueB), _svgHeaderFrame(hueB)));
    }

    function _svgHeaderDefs(uint256 hueA, uint256 hueB) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="290" height="500" viewBox="0 0 290 500" font-family="monospace">',
                '<defs>',
                '<linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
                '<stop offset="0%" stop-color="hsl(', hueA.toString(), ',70%,22%)">',
                '<animate attributeName="stop-color" values="hsl(', hueA.toString(), ',70%,22%);hsl(', hueB.toString(), ',70%,18%);hsl(', hueA.toString(), ',70%,22%)" dur="8s" repeatCount="indefinite"/>'
            )
        );
    }

    function _svgHeaderFrame(uint256 hueB) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '</stop>',
                '<stop offset="100%" stop-color="hsl(', hueB.toString(), ',80%,12%)"/>',
                '</linearGradient>',
                '</defs>',
                '<rect width="290" height="500" rx="20" fill="url(#bg)"/>',
                '<rect x="8" y="8" width="274" height="484" rx="14" fill="none" stroke="hsla(0,0%,100%,0.15)" stroke-width="1"/>'
            )
        );
    }

    function _svgOrbit(uint256 hueA, uint256 hueB, bool inRange) private pure returns (string memory) {
        string memory pulseColor = inRange ? "hsl(140,70%,55%)" : "hsl(40,90%,55%)";
        return string(
            abi.encodePacked(
                '<g transform="translate(145,180)">',
                '<circle r="46" fill="none" stroke="hsla(0,0%,100%,0.12)" stroke-width="1"/>',
                '<g>',
                '<animateTransform attributeName="transform" type="rotate" from="0 0 0" to="360 0 0" dur="14s" repeatCount="indefinite"/>',
                '<circle cx="46" cy="0" r="15" fill="hsl(', hueA.toString(), ',75%,55%)"/>',
                '<circle cx="-46" cy="0" r="15" fill="hsl(', hueB.toString(), ',75%,55%)"/>',
                '</g>',
                '<circle r="10" fill="', pulseColor, '">',
                '<animate attributeName="r" values="9;12;9" dur="2.2s" repeatCount="indefinite"/>',
                '<animate attributeName="opacity" values="1;0.6;1" dur="2.2s" repeatCount="indefinite"/>',
                '</circle>',
                '</g>'
            )
        );
    }

    function _svgWave(uint256 hueA) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g transform="translate(20,270)" opacity="0.8">',
                '<path d="M0,20 Q36,0 72,20 T144,20 T216,20 T250,20" fill="none" stroke="hsl(', hueA.toString(), ',80%,60%)" stroke-width="2.5" stroke-linecap="round" stroke-dasharray="6 8">',
                '<animate attributeName="stroke-dashoffset" values="0;-28" dur="2s" repeatCount="indefinite"/>',
                '</path>',
                '</g>'
            )
        );
    }

    function _svgText(SVGParams memory params) private pure returns (string memory) {
        return string(abi.encodePacked(_svgTextHeader(params), _svgTextFooter(params)));
    }

    function _svgTextHeader(SVGParams memory params) private pure returns (string memory) {
        string memory feeStr = _feeToPercent(params.fee);
        return string(
            abi.encodePacked(
                '<text x="24" y="40" fill="#fff" font-size="20" font-weight="bold">', params.token0Symbol, ' / ', params.token1Symbol, '</text>',
                '<text x="24" y="62" fill="hsla(0,0%,100%,0.65)" font-size="13">Archiel V3 Position &#183; ', feeStr, '</text>',
                '<text x="24" y="330" fill="hsla(0,0%,100%,0.55)" font-size="11">TICK RANGE</text>',
                '<text x="24" y="352" fill="#fff" font-size="14">', _int24ToStr(params.tickLower), '  &#8594;  ', _int24ToStr(params.tickUpper), '</text>'
            )
        );
    }

    function _svgTextFooter(SVGParams memory params) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<text x="24" y="400" fill="hsla(0,0%,100%,0.55)" font-size="11">STATUS</text>',
                '<text x="24" y="420" fill="#fff" font-size="14">', params.inRange ? unicode"● In range" : unicode"● Out of range", '</text>',
                '<text x="24" y="470" fill="hsla(0,0%,100%,0.4)" font-size="11">Position #', params.tokenId.toString(), '</text>'
            )
        );
    }

    function _int24ToStr(int24 tick) private pure returns (string memory) {
        return int256(tick).toString();
    }

    function _feeToPercent(uint24 fee) private pure returns (string memory) {
        // fee is in hundredths of a bip (1e-6); render as e.g. "0.30%"
        uint256 hundredths = uint256(fee) / 100; // -> value in bips*... simplify to 2dp percent
        uint256 whole = hundredths / 100;
        uint256 frac = hundredths % 100;
        string memory fracStr = frac < 10
            ? string(abi.encodePacked("0", frac.toString()))
            : frac.toString();
        return string(abi.encodePacked(whole.toString(), ".", fracStr, "%"));
    }
}
