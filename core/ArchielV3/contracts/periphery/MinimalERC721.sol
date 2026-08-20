// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MinimalERC721
/// @notice Self-contained ERC721 implementation (no external dependencies)
/// so ArchielV3PositionManager can be deployed on Arc Testnet without
/// relying on an OpenZeppelin import path being available.
abstract contract MinimalERC721 {
    string public name;
    string public symbol;

    error ERC721_ZeroAddress();
    error ERC721_NonexistentToken();
    error ERC721_ApproveToOwner();
    error ERC721_NotAuthorized();
    error ERC721_ApproveToSelf();
    error ERC721_WrongOwner();
    error ERC721_TransferToZero();
    error ERC721_MintToZero();
    error ERC721_AlreadyMinted();

    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _balances;
    mapping(uint256 => address) internal _tokenApprovals;
    mapping(address => mapping(address => bool)) internal _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function balanceOf(address ownerAddr) public view returns (uint256) {
        if (ownerAddr == address(0)) revert ERC721_ZeroAddress();
        return _balances[ownerAddr];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert ERC721_NonexistentToken();
        return tokenOwner;
    }

    function approve(address to, uint256 tokenId) public {
        address tokenOwner = ownerOf(tokenId);
        if (to == tokenOwner) revert ERC721_ApproveToOwner();
        if (msg.sender != tokenOwner && !_operatorApprovals[tokenOwner][msg.sender]) revert ERC721_NotAuthorized();
        _tokenApprovals[tokenId] = to;
        emit Approval(tokenOwner, to, tokenId);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        if (_owners[tokenId] == address(0)) revert ERC721_NonexistentToken();
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) public {
        if (operator == msg.sender) revert ERC721_ApproveToSelf();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address ownerAddr, address operator) public view returns (bool) {
        return _operatorApprovals[ownerAddr][operator];
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address tokenOwner = ownerOf(tokenId);
        return (spender == tokenOwner || getApproved(tokenId) == spender || isApprovedForAll(tokenOwner, spender));
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert ERC721_NotAuthorized();
        if (ownerOf(tokenId) != from) revert ERC721_WrongOwner();
        if (to == address(0)) revert ERC721_TransferToZero();

        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        transferFrom(from, to, tokenId);
    }

    function _mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert ERC721_MintToZero();
        if (_owners[tokenId] != address(0)) revert ERC721_AlreadyMinted();

        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function _burn(uint256 tokenId) internal {
        address tokenOwner = ownerOf(tokenId);
        delete _tokenApprovals[tokenId];
        _balances[tokenOwner] -= 1;
        delete _owners[tokenId];
        emit Transfer(tokenOwner, address(0), tokenId);
    }
}
