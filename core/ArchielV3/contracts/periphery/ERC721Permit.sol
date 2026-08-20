// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MinimalERC721.sol";

interface IERC1271 {
    /// @notice Must return this magic value if `signature` is a valid
    /// signature for `hash` by this contract, per EIP-1271.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}

/// @title ERC721Permit
/// @notice Archiel original — adds EIP-712 signature-based approval to
/// MinimalERC721, so a user can approve a spender (e.g. the router, in the
/// same transaction as a swap) with a signature instead of a separate
/// approve() transaction. Supports both EOA wallets (ecrecover) and smart
/// contract wallets — Safe, Argent, and other ERC-4337/programmable-auth
/// wallets increasingly common on Circle's Arc Network — via EIP-1271
/// (isValidSignature), matching the pattern Circle's own Gateway adopted
/// for the same reason: https://www.circle.com/blog/gateway-adds-erc-1271-support-for-programmable-authorization
abstract contract ERC721Permit is MinimalERC721 {
    bytes4 private constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    error ERC721Permit_Expired();
    error ERC721Permit_ApproveToOwner();
    error ERC721Permit_InvalidSignature();

    bytes32 public immutable DOMAIN_SEPARATOR;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");

    mapping(uint256 => uint256) public nonces;

    constructor(string memory _name, string memory _version) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(_name)),
                keccak256(bytes(_version)),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Approves `spender` for `tokenId` using an off-chain signature
    /// from the current owner, so the approval and the action that uses it
    /// (e.g. decreaseLiquidity, collect) can be batched via Multicall.
    ///
    /// `signature` is a raw byte string, not split into v/r/s, so it works
    /// for both:
    ///   - EOA wallets: the standard 65-byte (r, s, v) signature from
    ///     eth_signTypedData_v4 — verified here via ecrecover.
    ///   - Smart contract wallets: any length/format their own
    ///     isValidSignature() accepts (multisig approvals, passkeys, etc.) —
    ///     verified by calling the wallet contract itself per EIP-1271.
    /// Which path runs is decided by whether `tokenOwner` has code, not by
    /// signature length, since a contract wallet's own signature scheme may
    /// happen to also be 65 bytes.
    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert ERC721Permit_Expired();

        address tokenOwner = ownerOf(tokenId);
        if (spender == tokenOwner) revert ERC721Permit_ApproveToOwner();

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonces[tokenId], deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        if (!_isValidSignature(tokenOwner, digest, signature)) revert ERC721Permit_InvalidSignature();

        nonces[tokenId]++;
        _tokenApprovals[tokenId] = spender;
        emit Approval(tokenOwner, spender, tokenId);
    }

    function _isValidSignature(
        address signer,
        bytes32 digest,
        bytes calldata signature
    ) private view returns (bool) {
        if (signer.code.length == 0) {
            // EOA path — must be the standard 65-byte (r, s, v) layout.
            if (signature.length != 65) return false;
            bytes32 r; bytes32 s; uint8 v;
            assembly {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 32))
                v := byte(0, calldataload(add(signature.offset, 64)))
            }
            address recovered = ecrecover(digest, v, r, s);
            return recovered != address(0) && recovered == signer;
        } else {
            // Smart contract wallet path (EIP-1271) — the wallet decides
            // what counts as valid (multisig threshold, passkey, policy
            // checks, etc.); we only check it returns the magic value.
            (bool ok, bytes memory ret) = signer.staticcall(
                abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature)
            );
            return ok && ret.length == 32 && abi.decode(ret, (bytes4)) == ERC1271_MAGIC_VALUE;
        }
    }
}
