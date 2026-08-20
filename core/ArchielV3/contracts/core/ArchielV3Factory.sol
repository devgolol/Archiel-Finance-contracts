// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IArchielV3Pool.sol";

/// @title ArchielV3Factory
/// @notice Deploys and indexes ArchielV3Pool contracts, one per
/// (token0, token1, fee) combination. Fee tiers mirror common
/// concentrated-liquidity conventions (0.01% / 0.05% / 0.3% / 1%) but are
/// Archiel's own configuration and can be extended by the owner.
///
/// Pools are deployed as EIP-1167 minimal proxy clones of one shared
/// `poolImplementation` contract instead of full copies (`new ArchielV3Pool(...)`
/// would embed Pool's entire creation bytecode into Factory's own bytecode on
/// every compile, which pushed Factory past the 24,576-byte EIP-170 limit).
/// A clone is ~45 bytes of pure delegatecall-forwarding bytecode regardless
/// of how large the implementation is — this is the same technique
/// OpenZeppelin's Clones library and many production factories use.
contract ArchielV3Factory {
    event PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee, int24 tickSpacing, address pool);
    event FeeAmountEnabled(uint24 fee, int24 tickSpacing);
    event OwnerChanged(address oldOwner, address newOwner);

    error AV3F_NotOwner();
    error AV3F_ZeroAddress();
    error AV3F_FeeTooHigh();
    error AV3F_BadSpacing();
    error AV3F_AlreadyEnabled();
    error AV3F_IdenticalTokens();
    error AV3F_FeeNotEnabled();
    error AV3F_PoolExists();
    error AV3F_CloneFailed();

    address public owner;
    address public immutable poolImplementation;
    mapping(uint24 => int24) public feeAmountTickSpacing;
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    modifier onlyOwner() {
        if (msg.sender != owner) revert AV3F_NotOwner();
        _;
    }

    /// @param _poolImplementation Address of an ArchielV3Pool deployed with
    /// no constructor args — this Factory clones it for every new pool, so
    /// deploy that implementation FIRST and pass its address here.
    constructor(address _poolImplementation) {
        if (_poolImplementation == address(0)) revert AV3F_ZeroAddress();
        poolImplementation = _poolImplementation;

        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        // 0.01% — stablecoin-to-stablecoin pairs (e.g. USDC/EURC), tight tick
        // spacing since price barely moves off 1:1.
        feeAmountTickSpacing[100] = 1;
        emit FeeAmountEnabled(100, 1);

        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);

        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);

        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    function setOwner(address _owner) external onlyOwner {
        if (_owner == address(0)) revert AV3F_ZeroAddress();
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    function enableFeeAmount(uint24 fee, int24 tickSpacing) external onlyOwner {
        if (fee >= 1_000_000) revert AV3F_FeeTooHigh();
        if (tickSpacing <= 0 || tickSpacing >= 16384) revert AV3F_BadSpacing();
        if (feeAmountTickSpacing[fee] != 0) revert AV3F_AlreadyEnabled();

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        if (tokenA == tokenB) revert AV3F_IdenticalTokens();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert AV3F_ZeroAddress();

        int24 tickSpacing = feeAmountTickSpacing[fee];
        if (tickSpacing == 0) revert AV3F_FeeNotEnabled();
        if (getPool[token0][token1][fee] != address(0)) revert AV3F_PoolExists();

        pool = _cloneImplementation(keccak256(abi.encode(token0, token1, fee)));
        IArchielV3Pool(pool).initializeClone(token0, token1, fee, tickSpacing);

        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;

        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @dev Standard EIP-1167 minimal proxy deployment via CREATE2 —
    /// produces a contract whose entire runtime is just:
    /// "delegatecall everything to `poolImplementation`, return whatever it
    /// returns". Deterministic address (same salt ⇒ same address), same as
    /// the original `new ArchielV3Pool{salt: ...}(...)` this replaced.
    function _cloneImplementation(bytes32 salt) private returns (address instance) {
        address impl = poolImplementation;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert AV3F_CloneFailed();
    }
}
