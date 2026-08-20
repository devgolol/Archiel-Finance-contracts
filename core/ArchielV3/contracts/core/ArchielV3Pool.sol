// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/TickMath.sol";
import "../libraries/TickBitmap.sol";
import "../libraries/SwapMath.sol";
import "../libraries/SqrtPriceMath.sol";
import "../libraries/FullMath.sol";
import "../libraries/SafeERC20Minimal.sol";
import "../interfaces/IArchielV3Pool.sol";
import "../interfaces/IERC20Minimal.sol";

interface IArchielV3FactoryOwner {
    function owner() external view returns (address);
}

/// @title ArchielV3Pool
/// @notice Concentrated liquidity AMM pool for Archiel Finance on Arc Testnet.
/// Liquidity providers supply capital to custom price ranges (ticks) instead
/// of the full 0..infinity curve, and swaps pay a fee proportional to the
/// pool's fee tier. Architecture follows the tick/range-order model popularized
/// by concentrated-liquidity AMMs, reimplemented from scratch for Archiel.
///
/// NOTE: no TWAP oracle (unlike the original design) — it was cut purely to
/// fit under the EIP-170 24,576-byte contract-size limit alongside
/// everything else here. Swaps/liquidity are unaffected; only on-chain
/// historical-price queries (observe()) are unavailable. Can be re-added as
/// a separate satellite contract later if needed without touching this one.
contract ArchielV3Pool is IArchielV3Pool {
    using TickBitmap for mapping(int16 => uint256);
    using SafeERC20Minimal for address;

    // Custom errors instead of require(cond, "string") — each string literal
    // this replaces costs real deployed bytecode (Spurious Dragon caps a
    // contract at 24576 bytes), while a custom error is just a 4-byte
    // selector. Same revert behavior, much smaller runtime code.
    error AV3P_Locked();
    error AV3P_AlreadyInitialized();
    error AV3P_AlreadyClonedInit();
    error AV3P_NotFactoryOwner();
    error AV3P_BadProtocolFee();
    error AV3P_LiquidityOverflow();
    error AV3P_BadTickRange();
    error AV3P_TickOutOfRange();
    error AV3P_ZeroAmount();
    error AV3P_Amount0NotPaid();
    error AV3P_Amount1NotPaid();
    error AV3P_BadPriceLimit();

    // NOT immutable — this contract is deployed ONCE as a shared
    // "implementation" that every real pool is an EIP-1167 minimal proxy
    // (clone) of, to keep ArchielV3Factory's own deployed bytecode small
    // (embedding one full Pool per createPool() call blew Factory's size
    // past the 24,576-byte limit; a clone is ~45 bytes regardless of how
    // big this implementation is). Each clone has its own separate storage
    // even though they all delegatecall into this same contract's code, so
    // these behave exactly like immutables in practice — just set once, via
    // initializeClone() below, instead of a constructor argument.
    address public factory;
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;

    uint128 public maxLiquidityPerTick;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint8 feeProtocol;
        bool unlocked;
    }
    Slot0 public override slot0;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    ProtocolFees public protocolFees;

    uint128 public override liquidity;

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        bool initialized;
    }
    mapping(int24 => TickInfo) public ticks;
    mapping(int16 => uint256) public tickBitmap;

    struct PositionInfo {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }
    mapping(bytes32 => PositionInfo) public positions;

    event Initialize(uint160 sqrtPriceX96, int24 tick);
    event Mint(address indexed owner, int24 tickLower, int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1);
    event Burn(address indexed owner, int24 tickLower, int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1);
    event Collect(address indexed owner, address recipient, int24 tickLower, int24 tickUpper, uint128 amount0, uint128 amount1);
    event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick);

    modifier lock() {
        if (!slot0.unlocked) revert AV3P_Locked();
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @notice Locks this contract as an implementation the moment it is
    /// deployed, so `initializeClone()` below can never be called directly
    /// on the implementation address by anyone pretending to be a Factory.
    /// Runs exactly once, at deployment of the implementation itself — an
    /// EIP-1167 clone never executes this constructor (clones only
    /// delegatecall into the implementation's runtime code), so every real
    /// clone still starts with `factory == address(0)` as expected.
    constructor() {
        factory = address(0xdEaD);
    }

    /// @notice Called by ArchielV3Factory exactly once, immediately after it
    /// deploys a clone of this contract, to set what a constructor normally
    /// would. Guarded by `factory == address(0)` since a real clone always
    /// starts with empty storage; msg.sender is trusted as the Factory
    /// because only the Factory ever calls this right after CREATE2.
    function initializeClone(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) external {
        if (factory != address(0)) revert AV3P_AlreadyClonedInit();
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = _computeMaxLiquidityPerTick(_tickSpacing);
    }

    function _computeMaxLiquidityPerTick(int24 _tickSpacing) private pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / _tickSpacing) * _tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / _tickSpacing) * _tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / _tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function initialize(uint160 sqrtPriceX96) external override {
        if (slot0.sqrtPriceX96 != 0) revert AV3P_AlreadyInitialized();
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            feeProtocol: 0,
            unlocked: true
        });
        emit Initialize(sqrtPriceX96, tick);
    }

    /// @notice Sets the protocol's cut of swap fees (0 = disabled, else 1/N of LP fees), factory-owner only.
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external {
        if (msg.sender != IArchielV3FactoryOwner(factory).owner()) revert AV3P_NotFactoryOwner();
        bool validFee0 = feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10);
        bool validFee1 = feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10);
        if (!validFee0 || !validFee1) revert AV3P_BadProtocolFee();
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
    }

    /// @notice Withdraws accumulated protocol fees to `recipient`, factory-owner only.
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external lock returns (uint128 amount0, uint128 amount1) {
        if (msg.sender != IArchielV3FactoryOwner(factory).owner()) revert AV3P_NotFactoryOwner();

        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            protocolFees.token0 -= amount0;
            token0.safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            protocolFees.token1 -= amount1;
            token1.safeTransfer(recipient, amount1);
        }
    }

    // ---------------------------------------------------------------------
    // Liquidity provision
    // ---------------------------------------------------------------------

    function _positionKey(address owner, int24 tickLower, int24 tickUpper) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function _updateTick(int24 tick, int24 currentTick, int128 liquidityDelta, bool upper) private returns (bool flipped) {
        TickInfo storage info = ticks[tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = liquidityDelta < 0
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            : liquidityGrossBefore + uint128(liquidityDelta);
        if (liquidityGrossAfter > maxLiquidityPerTick) revert AV3P_LiquidityOverflow();

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            if (tick <= currentTick) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = upper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;
    }

    function _clearTick(int24 tick) private {
        delete ticks[tick];
    }

    function _getFeeGrowthInside(
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick
    ) private view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        TickInfo storage lower = ticks[tickLower];
        TickInfo storage upper = ticks[tickUpper];

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (currentTick >= tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (currentTick < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    function _modifyPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) private returns (int256 amount0, int256 amount1) {
        if (tickLower >= tickUpper) revert AV3P_BadTickRange();
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert AV3P_TickOutOfRange();

        Slot0 memory _slot0 = slot0;

        (bool flippedLower, bool flippedUpper) =
            _updateTicksAndSettleFees(owner, tickLower, tickUpper, _slot0.tick, liquidityDelta);

        if (liquidityDelta != 0) {
            (amount0, amount1) = _computeLiquidityDeltaAmounts(
                tickLower, tickUpper, _slot0.tick, _slot0.sqrtPriceX96, liquidityDelta
            );
        }

        if (liquidityDelta < 0) {
            if (flippedLower) _clearTick(tickLower);
            if (flippedUpper) _clearTick(tickUpper);
        }
    }

    /// @dev Flips/updates both boundary ticks (if liquidity changed), then
    /// settles this position's accrued fees against the latest fee-growth
    /// snapshot. Split out of _modifyPosition purely to keep that function's
    /// local-variable count low enough to compile without viaIR.
    function _updateTicksAndSettleFees(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        int128 liquidityDelta
    ) private returns (bool flippedLower, bool flippedUpper) {
        if (liquidityDelta != 0) {
            flippedLower = _updateTick(tickLower, currentTick, liquidityDelta, false);
            flippedUpper = _updateTick(tickUpper, currentTick, liquidityDelta, true);
            if (flippedLower) tickBitmap.flipTick(tickLower, tickSpacing);
            if (flippedUpper) tickBitmap.flipTick(tickUpper, tickSpacing);
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            _getFeeGrowthInside(tickLower, tickUpper, currentTick);

        _settlePositionFees(owner, tickLower, tickUpper, liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);
    }

    function _settlePositionFees(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) private {
        bytes32 key = _positionKey(owner, tickLower, tickUpper);
        PositionInfo storage position = positions[key];

        uint128 tokensOwed0 = uint128(FullMath.mulDiv(
            feeGrowthInside0X128 - position.feeGrowthInside0LastX128,
            position.liquidity,
            1 << 128
        ));
        uint128 tokensOwed1 = uint128(FullMath.mulDiv(
            feeGrowthInside1X128 - position.feeGrowthInside1LastX128,
            position.liquidity,
            1 << 128
        ));

        if (liquidityDelta < 0) {
            position.liquidity -= uint128(-liquidityDelta);
        } else if (liquidityDelta > 0) {
            position.liquidity += uint128(liquidityDelta);
        }
        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            position.tokensOwed0 += tokensOwed0;
            position.tokensOwed1 += tokensOwed1;
        }
    }

    /// @dev The three-branch (below/inside/above range) token-delta
    /// computation, split out of _modifyPosition for the same stack-depth
    /// reason as _updateTicksAndSettleFees above. Updates global `liquidity`
    /// directly when the range straddles the current price.
    function _computeLiquidityDeltaAmounts(
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint160 sqrtPriceX96Current,
        int128 liquidityDelta
    ) private returns (int256 amount0, int256 amount1) {
        uint128 absLiq = _absLiquidity(liquidityDelta);
        bool adding = liquidityDelta > 0;

        if (currentTick < tickLower) {
            amount0 = _signedAmount0(
                TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), absLiq, adding
            );
        } else if (currentTick < tickUpper) {
            amount0 = _signedAmount0(sqrtPriceX96Current, TickMath.getSqrtRatioAtTick(tickUpper), absLiq, adding);
            amount1 = _signedAmount1(TickMath.getSqrtRatioAtTick(tickLower), sqrtPriceX96Current, absLiq, adding);

            liquidity = liquidityDelta < 0
                ? liquidity - uint128(-liquidityDelta)
                : liquidity + uint128(liquidityDelta);
        } else {
            amount1 = _signedAmount1(
                TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), absLiq, adding
            );
        }
    }

    function _signedAmount0(uint160 sqrtA, uint160 sqrtB, uint128 absLiq, bool adding) private pure returns (int256 amt) {
        amt = int256(SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, absLiq, adding));
        if (!adding) amt = -amt;
    }

    function _signedAmount1(uint160 sqrtA, uint160 sqrtB, uint128 absLiq, bool adding) private pure returns (int256 amt) {
        amt = int256(SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, absLiq, adding));
        if (!adding) amt = -amt;
    }

    function _absLiquidity(int128 x) private pure returns (uint128) {
        return x < 0 ? uint128(-x) : uint128(x);
    }

    /// @notice Adds liquidity to a price range. Caller must repay owed tokens
    /// via archielV3MintCallback before this call returns.
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        if (amount == 0) revert AV3P_ZeroAmount();
        (int256 amount0Int, int256 amount1Int) =
            _modifyPosition(recipient, tickLower, tickUpper, int128(amount));

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before = amount0 > 0 ? IERC20Minimal(token0).balanceOf(address(this)) : 0;
        uint256 balance1Before = amount1 > 0 ? IERC20Minimal(token1).balanceOf(address(this)) : 0;

        IArchielV3MintCallback(msg.sender).archielV3MintCallback(amount0, amount1, data);

        if (amount0 > 0 && IERC20Minimal(token0).balanceOf(address(this)) < balance0Before + amount0) revert AV3P_Amount0NotPaid();
        if (amount1 > 0 && IERC20Minimal(token1).balanceOf(address(this)) < balance1Before + amount1) revert AV3P_Amount1NotPaid();

        emit Mint(recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @notice Removes liquidity from a price range. Owed tokens accrue to the
    /// position and must be withdrawn separately via collect().
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        (int256 amount0Int, int256 amount1Int) =
            _modifyPosition(msg.sender, tickLower, tickUpper, -int128(amount));

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
            PositionInfo storage position = positions[key];
            position.tokensOwed0 += uint128(amount0);
            position.tokensOwed1 += uint128(amount1);
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @notice Withdraws accrued fees and/or burned principal owed to a position
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
        PositionInfo storage position = positions[key];

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            token0.safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            token1.safeTransfer(recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    // ---------------------------------------------------------------------
    // Swapping
    // ---------------------------------------------------------------------

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 protocolFee;
        uint128 liquidity;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    /// @notice Swaps token0 for token1 (zeroForOne=true) or vice versa.
    /// exactInput when amountSpecified > 0, exactOutput when < 0.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override lock returns (int256 amount0, int256 amount1) {
        if (amountSpecified == 0) revert AV3P_ZeroAmount();
        Slot0 memory _slot0 = slot0;

        bool validPriceLimit = zeroForOne
            ? sqrtPriceLimitX96 < _slot0.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
            : sqrtPriceLimitX96 > _slot0.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO;
        if (!validPriceLimit) revert AV3P_BadPriceLimit();

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: _slot0.sqrtPriceX96,
            tick: _slot0.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: liquidity
        });

        uint8 feeProtocolThisDirection = zeroForOne
            ? (_slot0.feeProtocol % 16)
            : (_slot0.feeProtocol >> 4);

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            _swapStep(state, zeroForOne, amountSpecified, sqrtPriceLimitX96, feeProtocolThisDirection);
        }

        slot0.sqrtPriceX96 = state.sqrtPriceX96;
        slot0.tick = state.tick;
        liquidity = state.liquidity;

        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        (amount0, amount1) = zeroForOne == (amountSpecified > 0)
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        _settleSwap(recipient, zeroForOne, amount0, amount1, data);

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
    }

    /// @dev Executes ONE swap step (find next tick, run the step math, cross
    /// the tick if reached) and mutates `state` in place. Split out of swap()
    /// purely to keep swap()'s own local-variable count low enough to compile
    /// without viaIR — `state` is memory, so mutations here are visible to
    /// the caller without needing to return anything.
    function _swapStep(
        SwapState memory state,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint8 feeProtocolThisDirection
    ) private {
        StepState memory step;
        step.sqrtPriceStartX96 = state.sqrtPriceX96;

        (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
            state.tick,
            tickSpacing,
            zeroForOne
        );

        if (step.tickNext < TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
        else if (step.tickNext > TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;

        step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

        uint160 target = zeroForOne
            ? (step.sqrtPriceNextX96 < sqrtPriceLimitX96 ? sqrtPriceLimitX96 : step.sqrtPriceNextX96)
            : (step.sqrtPriceNextX96 > sqrtPriceLimitX96 ? sqrtPriceLimitX96 : step.sqrtPriceNextX96);

        SwapMath.StepResult memory sr = SwapMath.computeSwapStep(
            state.sqrtPriceX96,
            target,
            state.liquidity,
            state.amountSpecifiedRemaining,
            fee
        );
        state.sqrtPriceX96 = sr.sqrtRatioNextX96;
        step.amountIn = sr.amountIn;
        step.amountOut = sr.amountOut;
        step.feeAmount = sr.feeAmount;

        if (amountSpecified > 0) {
            state.amountSpecifiedRemaining -= int256(step.amountIn + step.feeAmount);
            state.amountCalculated -= int256(step.amountOut);
        } else {
            state.amountSpecifiedRemaining += int256(step.amountOut);
            state.amountCalculated += int256(step.amountIn + step.feeAmount);
        }

        if (feeProtocolThisDirection > 0) {
            uint256 delta = step.feeAmount / feeProtocolThisDirection;
            step.feeAmount -= delta;
            state.protocolFee += uint128(delta);
        }

        if (state.liquidity > 0) {
            state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, 1 << 128, state.liquidity);
        }

        _crossTickIfReached(state, step, zeroForOne);
    }

    /// @dev If the step landed exactly on the next initialized tick, flips
    /// the fee-growth-outside accounting for that tick and applies its
    /// liquidityNet to `state.liquidity`; otherwise just re-derives the tick
    /// from the new price. Split out of _swapStep for the same reason.
    function _crossTickIfReached(SwapState memory state, StepState memory step, bool zeroForOne) private {
        if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
            if (step.initialized) {
                if (zeroForOne) {
                    ticks[step.tickNext].feeGrowthOutside0X128 =
                        state.feeGrowthGlobalX128 - ticks[step.tickNext].feeGrowthOutside0X128;
                    ticks[step.tickNext].feeGrowthOutside1X128 =
                        feeGrowthGlobal1X128 - ticks[step.tickNext].feeGrowthOutside1X128;
                } else {
                    ticks[step.tickNext].feeGrowthOutside0X128 =
                        feeGrowthGlobal0X128 - ticks[step.tickNext].feeGrowthOutside0X128;
                    ticks[step.tickNext].feeGrowthOutside1X128 =
                        state.feeGrowthGlobalX128 - ticks[step.tickNext].feeGrowthOutside1X128;
                }
                int128 liquidityNet = ticks[step.tickNext].liquidityNet;
                if (zeroForOne) liquidityNet = -liquidityNet;
                state.liquidity = liquidityNet < 0
                    ? state.liquidity - uint128(-liquidityNet)
                    : state.liquidity + uint128(liquidityNet);
            }
            state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
        } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }
    }

    /// @dev Pays out the negative side and pulls in the positive side via the
    /// caller's callback, verifying the pool's balance actually increased by
    /// the expected amount. Split out of swap() for the same stack-depth reason.
    function _settleSwap(
        address recipient,
        bool zeroForOne,
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) private {
        if (zeroForOne) {
            if (amount1 < 0) token1.safeTransfer(recipient, uint256(-amount1));
            uint256 balance0Before = IERC20Minimal(token0).balanceOf(address(this));
            IArchielV3SwapCallback(msg.sender).archielV3SwapCallback(amount0, amount1, data);
            if (IERC20Minimal(token0).balanceOf(address(this)) < balance0Before + uint256(amount0)) revert AV3P_Amount0NotPaid();
        } else {
            if (amount0 < 0) token0.safeTransfer(recipient, uint256(-amount0));
            uint256 balance1Before = IERC20Minimal(token1).balanceOf(address(this));
            IArchielV3SwapCallback(msg.sender).archielV3SwapCallback(amount0, amount1, data);
            if (IERC20Minimal(token1).balanceOf(address(this)) < balance1Before + uint256(amount1)) revert AV3P_Amount1NotPaid();
        }
    }
}
