// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MinimalERC721.sol";
import "./ERC721Permit.sol";
import "./libraries/Multicall.sol";
import "../interfaces/IArchielV3Pool.sol";
import "../interfaces/IERC20Minimal.sol";
import "../core/ArchielV3Factory.sol";
import "../libraries/TickMath.sol";
import "../libraries/LiquidityAmounts.sol";
import "../libraries/SafeERC20Minimal.sol";

interface IERC20SymbolMinimal {
    function symbol() external view returns (string memory);
}

interface IArchielV3NFTDescriptor {
    function tokenURI(
        uint256 tokenId,
        string calldata token0Symbol,
        string calldata token1Symbol,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        address pool,
        bool inRange
    ) external pure returns (string memory);
}

error AV3PM_Expired();
error AV3PM_NotAuthorized();
error AV3PM_PoolNotFound();
error AV3PM_Slippage();
error AV3PM_PoolNotInitialized();
error AV3PM_UnauthorizedCallback();
error AV3PM_InsufficientLiquidity();
error AV3PM_NotEmpty();
error AV3PM_NonexistentToken();

/// @title ArchielV3PositionManager
/// @notice Wraps concentrated-liquidity positions as transferable NFTs so
/// users hold one ERC721 per range instead of interacting with pool
/// contracts and raw position keys directly.
contract ArchielV3PositionManager is ERC721Permit, IArchielV3MintCallback, Multicall {
    using SafeERC20Minimal for address;

    ArchielV3Factory public immutable factory;
    IArchielV3NFTDescriptor public immutable nftDescriptor;

    struct Position {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => Position) public positionsById;
    uint256 private _nextTokenId = 1;

    struct MintCallbackData {
        address token0;
        address token1;
        address payer;
    }

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert AV3PM_Expired();
        _;
    }

    modifier onlyPositionOwner(uint256 tokenId) {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert AV3PM_NotAuthorized();
        _;
    }

    constructor(address _factory, address _nftDescriptor)
        MinimalERC721("Archiel V3 Position", "ARCLV3-POS")
        ERC721Permit("Archiel V3 Position", "1")
    {
        factory = ArchielV3Factory(_factory);
        nftDescriptor = IArchielV3NFTDescriptor(_nftDescriptor);
    }

    function _pool(address token0, address token1, uint24 fee) private view returns (IArchielV3Pool) {
        address p = factory.getPool(token0, token1, fee);
        if (p == address(0)) revert AV3PM_PoolNotFound();
        return IArchielV3Pool(p);
    }

    /// @notice Provides liquidity to a new range and mints a position NFT to `recipient`.
    function mint(MintParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidityMinted, uint256 amount0, uint256 amount1)
    {
        (address token0, address token1) = params.token0 < params.token1
            ? (params.token0, params.token1)
            : (params.token1, params.token0);

        IArchielV3Pool pool = _pool(token0, token1, params.fee);

        liquidityMinted = _estimateLiquidity(pool, params);

        (amount0, amount1) = pool.mint(
            address(this),
            params.tickLower,
            params.tickUpper,
            liquidityMinted,
            abi.encode(MintCallbackData({token0: token0, token1: token1, payer: msg.sender}))
        );

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert AV3PM_Slippage();

        tokenId = _nextTokenId++;
        _mint(params.recipient, tokenId);
        _storePosition(tokenId, address(pool), params.tickLower, params.tickUpper, liquidityMinted);
    }

    /// @dev Split out of mint() purely to keep that function's local-variable
    /// count low enough to compile without viaIR.
    function _storePosition(
        uint256 tokenId,
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) private {
        positionsById[tokenId] = Position({
            pool: pool,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
    }

    /// @dev Computes the exact liquidity value that consumes at most the
    /// desired token amounts at the pool's current price, using the same
    /// range math the pool itself uses internally.
    function _estimateLiquidity(IArchielV3Pool pool, MintParams calldata params) private view returns (uint128) {
        (uint160 sqrtPriceX96Now, , , ) = pool.slot0(); // pool must be initialized
        if (sqrtPriceX96Now == 0) revert AV3PM_PoolNotInitialized();

        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96Now,
            TickMath.getSqrtRatioAtTick(params.tickLower),
            TickMath.getSqrtRatioAtTick(params.tickUpper),
            params.amount0Desired,
            params.amount1Desired
        );
    }

    function archielV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        MintCallbackData memory cbData = abi.decode(data, (MintCallbackData));
        if (msg.sender != address(_pool(cbData.token0, cbData.token1, IArchielV3Pool(msg.sender).fee())))
            revert AV3PM_UnauthorizedCallback();

        if (amount0Owed > 0) cbData.token0.safeTransferFrom(cbData.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) cbData.token1.safeTransferFrom(cbData.payer, msg.sender, amount1Owed);
    }

    /// @notice Adds more liquidity to an existing position NFT.
    function increaseLiquidity(
        uint256 tokenId,
        uint128 liquidityDelta,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external checkDeadline(deadline) onlyPositionOwner(tokenId) returns (uint256 amount0, uint256 amount1) {
        Position storage pos = positionsById[tokenId];
        (amount0, amount1) = _increaseLiquidityInternal(pos, liquidityDelta);
        if (amount0 < amount0Min || amount1 < amount1Min) revert AV3PM_Slippage();
        pos.liquidity += liquidityDelta;
    }

    /// @dev Split out of increaseLiquidity() for the same stack-depth reason
    /// as _storePosition above — `pos` is a storage ref, so mutating/reading
    /// it here is equivalent to doing it inline in the caller.
    function _increaseLiquidityInternal(
        Position storage pos,
        uint128 liquidityDelta
    ) private returns (uint256 amount0, uint256 amount1) {
        IArchielV3Pool pool = IArchielV3Pool(pos.pool);
        (amount0, amount1) = pool.mint(
            address(this),
            pos.tickLower,
            pos.tickUpper,
            liquidityDelta,
            abi.encode(MintCallbackData({token0: pool.token0(), token1: pool.token1(), payer: msg.sender}))
        );
    }

    /// @notice Removes liquidity from a position; owed tokens accrue for a later collect().
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidityDelta,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external checkDeadline(deadline) onlyPositionOwner(tokenId) returns (uint256 amount0, uint256 amount1) {
        Position storage pos = positionsById[tokenId];
        (amount0, amount1) = _decreaseLiquidityInternal(pos, liquidityDelta);
        if (amount0 < amount0Min || amount1 < amount1Min) revert AV3PM_Slippage();
    }

    /// @dev Split out of decreaseLiquidity() for the same stack-depth reason
    /// as _storePosition above.
    function _decreaseLiquidityInternal(
        Position storage pos,
        uint128 liquidityDelta
    ) private returns (uint256 amount0, uint256 amount1) {
        if (pos.liquidity < liquidityDelta) revert AV3PM_InsufficientLiquidity();
        IArchielV3Pool pool = IArchielV3Pool(pos.pool);

        (amount0, amount1) = pool.burn(pos.tickLower, pos.tickUpper, liquidityDelta);

        pos.liquidity -= liquidityDelta;
        pos.tokensOwed0 += uint128(amount0);
        pos.tokensOwed1 += uint128(amount1);
    }

    /// @notice Withdraws owed tokens (fees + any burned principal) to `recipient`.
    function collect(
        uint256 tokenId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    ) external onlyPositionOwner(tokenId) returns (uint128 amount0, uint128 amount1) {
        Position storage pos = positionsById[tokenId];
        return _collectInternal(pos, recipient, amount0Max, amount1Max);
    }

    /// @dev Split out of collect() for the same stack-depth reason as
    /// _storePosition above.
    function _collectInternal(
        Position storage pos,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    ) private returns (uint128 amount0, uint128 amount1) {
        IArchielV3Pool pool = IArchielV3Pool(pos.pool);

        // Realize latest fees into tokensOwed by nudging the position with a zero-liquidity burn
        if (pos.liquidity > 0) {
            pool.burn(pos.tickLower, pos.tickUpper, 0);
        }

        (amount0, amount1) = pool.collect(recipient, pos.tickLower, pos.tickUpper, amount0Max, amount1Max);
    }

    /// @notice Burns an emptied position NFT (liquidity and owed tokens must already be zero).
    function burnPosition(uint256 tokenId) external onlyPositionOwner(tokenId) {
        Position storage pos = positionsById[tokenId];
        if (pos.liquidity != 0 || pos.tokensOwed0 != 0 || pos.tokensOwed1 != 0) revert AV3PM_NotEmpty();
        delete positionsById[tokenId];
        _burn(tokenId);
    }

    /// @notice Returns the on-chain, animated SVG metadata for a position NFT.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert AV3PM_NonexistentToken();
        Position storage pos = positionsById[tokenId];
        return _buildTokenURI(tokenId, pos.pool, pos.tickLower, pos.tickUpper);
    }

    /// @dev Split out of tokenURI() for the same stack-depth reason as
    /// _storePosition above — takes plain scalars instead of a storage
    /// struct ref, so nothing from `pos` needs to stay reachable while the
    /// external call to nftDescriptor is being built.
    function _buildTokenURI(
        uint256 tokenId,
        address poolAddr,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (string memory) {
        (string memory symbol0, string memory symbol1, uint24 fee, bool inRange) =
            _gatherTokenURIData(poolAddr, tickLower, tickUpper);

        return nftDescriptor.tokenURI(
            tokenId,
            symbol0,
            symbol1,
            fee,
            tickLower,
            tickUpper,
            poolAddr,
            inRange
        );
    }

    /// @dev Split out of _buildTokenURI() for the same stack-depth reason —
    /// resolves `pool` and reads everything off it in its OWN frame, so by
    /// the time the (8-argument) external call to nftDescriptor happens in
    /// the caller, `pool` itself no longer needs to be kept reachable.
    function _gatherTokenURIData(
        address poolAddr,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (string memory symbol0, string memory symbol1, uint24 fee, bool inRange) {
        IArchielV3Pool pool = IArchielV3Pool(poolAddr);
        symbol0 = _trySymbol(pool.token0());
        symbol1 = _trySymbol(pool.token1());
        fee = pool.fee();
        (, int24 currentTick, , ) = pool.slot0();
        inRange = currentTick >= tickLower && currentTick < tickUpper;
    }

    function _trySymbol(address token) private view returns (string memory) {
        try IERC20SymbolMinimal(token).symbol() returns (string memory s) {
            return bytes(s).length == 0 ? "TOKEN" : s;
        } catch {
            return "TOKEN";
        }
    }
}
