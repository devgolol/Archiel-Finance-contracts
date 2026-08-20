// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// -----------------------------------------------------------------------
/// Minimal interfaces into ArchielSwap V3 (concentrated liquidity).
/// Mirrors the exact function signatures the Archiel frontend already
/// calls against CONTRACT_V3_FACTORY / CONTRACT_V3_POSITION_MANAGER, so
/// this vault composes with the deployed V3 contracts without needing
/// their full source.
/// -----------------------------------------------------------------------
interface IArchielSwapFactoryV3 {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev Read-only slice of the real ArchielV3Pool — just enough to convert
/// desired token amounts into a liquidity delta before calling
/// increaseLiquidity(). Slot0 here is genuinely 4 fields (sqrtPriceX96, tick,
/// feeProtocol, unlocked) — the deployed ArchielV3Pool has no oracle ring
/// buffer, so there's no observationIndex/observationCardinality to decode.
interface IArchielV3PoolMinimal {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint8 feeProtocol, bool unlocked);
}

interface IArchielSwapPositionManagerV3 {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 gridLower;
        int24 gridUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @dev Matches the deployed ArchielV3PositionManager exactly: unlike the
    /// Uniswap-official pattern, this contract does NOT accept desired token
    /// amounts here — the caller must already know how much liquidity they
    /// want and pass that directly. amount0Min/amount1Min are still slippage
    /// floors on the resulting token amounts. See _liquidityForAmounts()
    /// below for how this vault computes liquidityDelta before calling this.
    function increaseLiquidity(
        uint256 tokenId,
        uint128 liquidityDelta,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function collect(
        uint256 tokenId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    ) external returns (uint256 amount0, uint256 amount1);

    /// @dev The deployed contract has no `positions()` function — Position is
    /// only exposed via the public `positionsById` mapping, whose auto
    /// getter is named `positionsById`, not `positions`. Field order matches
    /// the real Position struct exactly (pool, tickLower, tickUpper,
    /// liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128,
    /// tokensOwed0, tokensOwed1); this interface just relabels
    /// tickLower/tickUpper as gridLower/gridUpper for readability — ABI
    /// encoding is positional, so the different names don't matter on chain.
    function positionsById(uint256 tokenId)
        external
        view
        returns (
            address pool,
            int24 gridLower,
            int24 gridUpper,
            uint128 liquidity,
            uint256 innerFee0LastX128,
            uint256 innerFee1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

/// -----------------------------------------------------------------------
/// Local copies of FullMath.mulDiv and TickMath.getSqrtRatioAtTick, ported
/// verbatim from the deployed ArchielV3 libraries (libraries/FullMath.sol,
/// libraries/TickMath.sol) so this vault can convert desired token amounts
/// into a liquidityDelta without needing an external call to those
/// libraries (their functions are `internal`, so they aren't independently
/// callable on-chain — each contract that needs them must compile its own
/// copy in). getTickAtSqrtRatio is intentionally omitted: the vault only
/// ever needs sqrtRatio-at-a-known-tick (its own gridLower/gridUpper), never
/// the reverse direction.
/// -----------------------------------------------------------------------
library FullMathLocal {
    error FM_DivByZero();
    error FM_Overflow();

    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                if (denominator == 0) revert FM_DivByZero();
                assembly { result := div(prod0, denominator) }
                return result;
            }
            if (denominator <= prod1) revert FM_Overflow();
            uint256 remainder;
            assembly { remainder := mulmod(a, b, denominator) }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
        }
    }
}

library TickMathLocal {
    error TM_BadTick();
    int24 internal constant MAX_TICK = 887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert TM_BadTick();
            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }
}

library LiquidityAmountsLocal {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal pure returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMathLocal.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        liquidity = uint128(FullMathLocal.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal pure returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        liquidity = uint128(FullMathLocal.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }
}

/// @title ArchielVaultV3
/// @notice Auto-compounding vault built on top of ArchielSwap V3 (concentrated
///         liquidity). Unlike its predecessor, which pooled fungible LP
///         shares on a constant-product pool (always full-range) — this
///         vault owns a single grid-ranged NFT position
///         per registered pair via ArchielSwapPositionManagerV3, and tracks
///         each depositor's proportional claim on that position's liquidity
///         as an internal vault-share balance.
///
///         A "pair" here means (token0, token1, fee) — a vault pair is
///         identified by fee tier too, not just the two tokens, so REGAR/
///         USDC at 0.05% and REGAR/USDC at 0.30% are two entirely separate
///         registrations with their own position, shares, and depositors.
///         Every function that touches a specific pair (deposit/withdraw/
///         harvest/rebalance/setVaultPairActive/getVaultPosition) takes
///         `fee` as an explicit argument for exactly this reason — passing
///         the wrong fee simply targets a different (or unregistered) pair,
///         it doesn't get silently coerced to "the" REGAR/USDC vault.
///
///         Flow per pair:
///           - addVaultPair(): owner registers a (token pair, fee tier) with
///             a grid (tick) range — full-range (V3_MIN_GRID..V3_MAX_GRID)
///             for "just work like V2" behavior, or a tighter custom range
///             for higher fee density. No position is minted yet.
///           - deposit(): first depositor mints the position; every
///             depositor after that increases liquidity on the same
///             position. Vault shares are minted proportional to the
///             liquidity added. Takes amountAMin/amountBMin like withdraw()
///             does, so a price move between signing and confirmation can't
///             silently mint the position at a worse ratio than the caller
///             accepted.
///           - harvest(): collects accrued swap fees from the position,
///             skims a performance fee to the treasury and a small keeper
///             reward to whoever called it, and reinvests the rest as more
///             liquidity on the same position — compounding everyone's
///             shares without minting new ones. Callable by anyone, on
///             purpose: the caller reward is what makes it worth a bot's
///             time to keep this running without babysitting.
///           - withdraw(): burns shares, decreases a proportional slice of
///             the position's liquidity, and sends the freed tokens
///             straight to the user (any fees still sitting in the
///             position's tokensOwed are left untouched for the next
///             harvest, so a withdraw never siphons off unharvested fees).
///           - rebalance(): owner-only. Closes the current position and
///             re-mints it around a new grid range — needed periodically
///             because, unlike a V2 pool, a V3 position stops earning fees
///             once price moves outside its range.
///
///         deposit() measures tokens actually received via a balance diff
///         rather than trusting the desired amount, so a fee-on-transfer
///         token can't silently break share accounting on the way in. This
///         does NOT extend to rebasing tokens changing balance *after*
///         they're inside an ArchielSwap V3 position — that's a property of
///         the AMM itself, outside what this vault (or any LP position) can
///         control, so rebasing tokens still aren't safe to register here.
///
///         The very first deposit() on a pair locks MINIMUM_LIQUIDITY_LOCK
///         shares to address(0) instead of handing 100% of the share supply
///         to that first depositor — same purpose as Uniswap V2's
///         MINIMUM_LIQUIDITY. See the constant's own comment for the
///         specific griefing pattern this closes off.
///
///         Testnet demo contract — not audited. Has an owner-only global
///         pause() (blocks new deposits, never withdraw/harvest) and a
///         per-pair active flag for disabling just one problematic pair,
///         but no full emergency-withdraw path beyond that.
contract ArchielVaultV3 is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant PERFORMANCE_FEE_BPS = 500; // 5%
    uint256 public constant HARVEST_CALLER_REWARD_BPS = 50; // 0.5% of harvested fees, paid to whoever calls harvest()
    uint256 private constant BPS_DENOMINATOR = 10_000;
    // Permanently locked to address(0) out of the very first deposit on each pair,
    // same purpose as Uniswap V2's MINIMUM_LIQUIDITY. Without this, a first
    // depositor who owns 100% of a pair's shares could have someone else donate
    // liquidity straight to the vault's tokenId via positionManager.increaseLiquidity()
    // (that call has no ownership check — anyone can add liquidity to any tokenId),
    // inflating liquidityBefore so the next real depositor's share of it rounds down
    // to zero and their deposit() call reverts. Reverting can't lose the depositor's
    // funds (Solidity unwinds the whole tx), but it can make a pair impossible to
    // deposit into. Locking a small amount of shares to nobody from the start means
    // the first depositor never owns the full share supply, raising the cost of that
    // griefing attempt without changing normal deposit/withdraw math at all.
    uint256 public constant MINIMUM_LIQUIDITY_LOCK = 1000;

    IArchielSwapPositionManagerV3 public immutable positionManager;
    IArchielSwapFactoryV3 public immutable factory;
    address public treasury;

    struct VaultPair {
        address token0;
        address token1;
        uint24 fee;
        int24 gridLower;
        int24 gridUpper;
        uint256 tokenId;          // ArchielSwap V3 position NFT id, 0 until first deposit
        uint128 liquidity;        // vault's tracked liquidity on that position
        uint256 totalVaultShares; // sum of all depositors' shares for this pair
        bool exists;
        bool active;              // false = deposits blocked for this pair, but withdraw/harvest still work
    }

    mapping(bytes32 => VaultPair) public vaultPairs;
    mapping(bytes32 => mapping(address => uint256)) public shareOf; // pairId => user => shares
    bytes32[] private _allPairIds;

    // Emergency brake: blocks new deposit() calls across every pair when true.
    // Deliberately does NOT touch withdraw()/harvest() — an emergency pause
    // must never trap user funds, only stop new capital from coming in while
    // the team investigates. Use setVaultPairActive() instead to disable a
    // single problematic pair without affecting the rest of the vault.
    bool public paused;

    event VaultPairAdded(bytes32 indexed pairId, address token0, address token1, uint24 fee, int24 gridLower, int24 gridUpper);
    event VaultPairActiveSet(bytes32 indexed pairId, bool active);
    event PausedSet(bool paused);
    event Deposit(bytes32 indexed pairId, address indexed user, uint256 amount0, uint256 amount1, uint256 sharesMinted);
    event Withdraw(bytes32 indexed pairId, address indexed user, uint256 amount0, uint256 amount1, uint256 sharesBurned);
    event Harvest(bytes32 indexed pairId, address indexed caller, uint256 fee0ToTreasury, uint256 fee1ToTreasury, uint256 reward0ToCaller, uint256 reward1ToCaller, uint128 liquidityAdded);
    event Rebalanced(bytes32 indexed pairId, uint256 oldTokenId, uint256 newTokenId, int24 newGridLower, int24 newGridUpper);

    modifier whenNotPaused() {
        require(!paused, "Vault: deposits are paused");
        _;
    }

    constructor(address _positionManager, address _factory, address _treasury) Ownable(msg.sender) {
        require(_positionManager != address(0) && _factory != address(0) && _treasury != address(0), "Vault: zero address");
        positionManager = IArchielSwapPositionManagerV3(_positionManager);
        factory = IArchielSwapFactoryV3(_factory);
        treasury = _treasury;
    }

    // ── Owner administration ────────────────────────────────────────────

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Vault: zero address");
        treasury = newTreasury;
    }

    /// @notice Emergency brake for the whole vault: blocks new deposit()
    ///         calls (every pair) until unpaused. withdraw() and harvest()
    ///         keep working regardless — depositors must always be able to
    ///         exit, pause or not.
    function setPaused(bool status) external onlyOwner {
        paused = status;
        emit PausedSet(status);
    }

    /// @notice Soft-disables a single pair: blocks new deposits into it
    ///         without touching withdraw()/harvest() for depositors already
    ///         in it, and without disturbing any other pair. Use this
    ///         instead of trying to "remove" a pair outright — a hard
    ///         delete would orphan any shares/position that still exist.
    function setVaultPairActive(address tokenA, address tokenB, uint24 fee, bool active) external onlyOwner {
        bytes32 pairId = _pairId2(tokenA, tokenB, fee);
        VaultPair storage vp = vaultPairs[pairId];
        require(vp.exists, "Vault: pair not registered");
        vp.active = active;
        emit VaultPairActiveSet(pairId, active);
    }

    /// @notice Registers a new pair for the vault. The pool must already
    ///         exist on ArchielSwapFactoryV3 (create it from the Pools
    ///         admin panel first, same as any other V3 pair).
    function addVaultPair(address tokenA, address tokenB, uint24 fee, int24 gridLower, int24 gridUpper) external onlyOwner {
        require(tokenA != tokenB, "Vault: same token");
        require(gridLower < gridUpper, "Vault: bad grid range");
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        address pool = factory.getPool(token0, token1, fee);
        require(pool != address(0), "Vault: pool not found on ArchielSwap V3");

        bytes32 pairId = _pairId(token0, token1, fee);
        require(!vaultPairs[pairId].exists, "Vault: this pair+fee combination is already registered");

        vaultPairs[pairId] = VaultPair({
            token0: token0,
            token1: token1,
            fee: fee,
            gridLower: gridLower,
            gridUpper: gridUpper,
            tokenId: 0,
            liquidity: 0,
            totalVaultShares: 0,
            exists: true,
            active: true
        });
        _allPairIds.push(pairId);
        emit VaultPairAdded(pairId, token0, token1, fee, gridLower, gridUpper);
    }

    function getAllVaultPairs() external view returns (bytes32[] memory) {
        return _allPairIds;
    }

    /// @notice Closes the pair's current position and re-mints it around a
    ///         new grid range. Needed periodically because a concentrated
    ///         position earns nothing once price drifts outside its range.
    function rebalance(
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 newGridLower,
        int24 newGridUpper,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external onlyOwner nonReentrant {
        require(newGridLower < newGridUpper, "Vault: bad grid range");
        bytes32 pairId = _pairId2(tokenA, tokenB, fee);
        VaultPair storage vp = vaultPairs[pairId];
        require(vp.exists, "Vault: pair not registered");
        require(vp.tokenId != 0, "Vault: no position yet");

        uint256 oldTokenId = vp.tokenId;
        uint128 liveLiquidity = _liveLiquidity(oldTokenId); // ground truth, not vp.liquidity
        require(liveLiquidity > 0, "Vault: nothing to rebalance");
        positionManager.decreaseLiquidity(oldTokenId, liveLiquidity, 0, 0, deadline);
        positionManager.collect(oldTokenId, address(this), type(uint128).max, type(uint128).max);

        uint256 amount0Desired = IERC20(vp.token0).balanceOf(address(this));
        uint256 amount1Desired = IERC20(vp.token1).balanceOf(address(this));
        _approveIfNeeded(vp.token0, amount0Desired);
        _approveIfNeeded(vp.token1, amount1Desired);

        (uint256 newTokenId, uint128 newLiquidity, , ) = positionManager.mint(
            IArchielSwapPositionManagerV3.MintParams({
                token0: vp.token0,
                token1: vp.token1,
                fee: vp.fee,
                gridLower: newGridLower,
                gridUpper: newGridUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: address(this),
                deadline: deadline
            })
        );

        vp.tokenId = newTokenId;
        vp.liquidity = newLiquidity;
        vp.gridLower = newGridLower;
        vp.gridUpper = newGridUpper;
        emit Rebalanced(pairId, oldTokenId, newTokenId, newGridLower, newGridUpper);
    }

    // ── Depositor actions ───────────────────────────────────────────────

    function deposit(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 sharesMinted) {
        require(amountADesired > 0 && amountBDesired > 0, "Vault: zero amount");
        bytes32 pairId = _pairId2(tokenA, tokenB, fee);
        VaultPair storage vp = vaultPairs[pairId];
        require(vp.exists, "Vault: pair not registered");
        require(vp.active, "Vault: this pair is not accepting deposits right now");

        (uint256 amount0Desired, uint256 amount1Desired) = tokenA == vp.token0
            ? (amountADesired, amountBDesired)
            : (amountBDesired, amountADesired);
        // Same reordering for the caller-supplied minimums, so they land on
        // the same token0/token1 slots as the desired amounts above.
        (uint256 amount0Min, uint256 amount1Min) = tokenA == vp.token0
            ? (amountAMin, amountBMin)
            : (amountBMin, amountAMin);

        // Measure what actually landed rather than trusting the desired amount —
        // protects the vault (and correct share accounting) if either token
        // turns out to be fee-on-transfer or otherwise short-transfers. Standard
        // ERC20s land exactly amount0Desired/amount1Desired here at zero extra
        // cost, so this is a no-op for the tokens the vault expects.
        uint256 bal0Before = IERC20(vp.token0).balanceOf(address(this));
        uint256 bal1Before = IERC20(vp.token1).balanceOf(address(this));
        IERC20(vp.token0).safeTransferFrom(msg.sender, address(this), amount0Desired);
        IERC20(vp.token1).safeTransferFrom(msg.sender, address(this), amount1Desired);
        amount0Desired = IERC20(vp.token0).balanceOf(address(this)) - bal0Before;
        amount1Desired = IERC20(vp.token1).balanceOf(address(this)) - bal1Before;
        require(amount0Desired > 0 && amount1Desired > 0, "Vault: nothing received (fee-on-transfer token?)");
        _approveIfNeeded(vp.token0, amount0Desired);
        _approveIfNeeded(vp.token1, amount1Desired);

        uint128 liquidityAdded;
        uint256 used0;
        uint256 used1;

        if (vp.tokenId == 0) {
            (uint256 tokenId, uint128 liq, uint256 u0, uint256 u1) = positionManager.mint(
                IArchielSwapPositionManagerV3.MintParams({
                    token0: vp.token0,
                    token1: vp.token1,
                    fee: vp.fee,
                    gridLower: vp.gridLower,
                    gridUpper: vp.gridUpper,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    recipient: address(this),
                    deadline: deadline
                })
            );
            vp.tokenId = tokenId;
            liquidityAdded = liq;
            used0 = u0;
            used1 = u1;
            // Bootstrap: shares == liquidity units, minus a small amount permanently
            // locked to nobody — see MINIMUM_LIQUIDITY_LOCK above for why.
            require(uint256(liq) > MINIMUM_LIQUIDITY_LOCK, "Vault: initial deposit too small");
            sharesMinted = uint256(liq) - MINIMUM_LIQUIDITY_LOCK;
            shareOf[pairId][address(0)] += MINIMUM_LIQUIDITY_LOCK;
            vp.totalVaultShares += MINIMUM_LIQUIDITY_LOCK;
        } else {
            // Read the position's real liquidity instead of trusting vp.liquidity —
            // see _liveLiquidity() for why: someone could have added liquidity to
            // this tokenId directly via the position manager, outside the vault.
            uint256 liquidityBefore = _liveLiquidity(vp.tokenId);
            uint128 liquidityDelta = _liquidityForAmounts(vp, amount0Desired, amount1Desired);
            require(liquidityDelta > 0, "Vault: amount too small");
            (uint256 u0, uint256 u1) = positionManager.increaseLiquidity(
                vp.tokenId, liquidityDelta, amount0Min, amount1Min, deadline
            );
            liquidityAdded = liquidityDelta;
            used0 = u0;
            used1 = u1;
            sharesMinted = liquidityBefore > 0
                ? (uint256(liquidityDelta) * vp.totalVaultShares) / liquidityBefore
                : uint256(liquidityDelta);
        }
        require(sharesMinted > 0, "Vault: deposit too small");

        vp.liquidity = _liveLiquidity(vp.tokenId); // resync from ground truth, not += liquidityAdded
        vp.totalVaultShares += sharesMinted;
        shareOf[pairId][msg.sender] += sharesMinted;

        // Refund any leftover dust the position manager didn't pull in
        // (amounts desired vs. amounts actually used can differ slightly
        // due to the pool's current price ratio).
        if (amount0Desired > used0) IERC20(vp.token0).safeTransfer(msg.sender, amount0Desired - used0);
        if (amount1Desired > used1) IERC20(vp.token1).safeTransfer(msg.sender, amount1Desired - used1);

        emit Deposit(pairId, msg.sender, used0, used1, sharesMinted);
    }

    function withdraw(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint256 sharesToBurn,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountAOut, uint256 amountBOut) {
        require(sharesToBurn > 0, "Vault: zero shares");
        bytes32 pairId = _pairId2(tokenA, tokenB, fee);
        VaultPair storage vp = vaultPairs[pairId];
        require(vp.exists, "Vault: pair not registered");
        require(shareOf[pairId][msg.sender] >= sharesToBurn, "Vault: insufficient shares");

        // Ground truth, not vp.liquidity — see _liveLiquidity().
        uint128 currentLiquidity = _liveLiquidity(vp.tokenId);
        uint128 liquidityToRemove = uint128((uint256(currentLiquidity) * sharesToBurn) / vp.totalVaultShares);
        require(liquidityToRemove > 0, "Vault: amount too small");

        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(
            vp.tokenId, liquidityToRemove, 0, 0, deadline
        );
        // Collect exactly the principal just freed — any fees still sitting
        // in tokensOwed from before this call are left in the position for
        // the next harvest(), so a withdraw can never skim unharvested fees.
        (uint256 collected0, uint256 collected1) = positionManager.collect(
            vp.tokenId, msg.sender, uint128(amount0), uint128(amount1)
        );

        (amountAOut, amountBOut) = tokenA == vp.token0 ? (collected0, collected1) : (collected1, collected0);
        require(amountAOut >= amountAMin && amountBOut >= amountBMin, "Vault: slippage");

        vp.liquidity = _liveLiquidity(vp.tokenId); // resync from ground truth
        vp.totalVaultShares -= sharesToBurn;
        shareOf[pairId][msg.sender] -= sharesToBurn;

        emit Withdraw(pairId, msg.sender, collected0, collected1, sharesToBurn);
    }

    /// @notice Collects accrued swap fees, skims the performance fee, and
    ///         reinvests the rest as liquidity on the same position.
    ///         Callable by anyone — there's
    ///         nothing to gain from calling it early since it only compounds
    ///         existing depositors' shares, never mints new ones.
    function harvest(address tokenA, address tokenB, uint24 fee, uint256 minLiquidityOut, uint256 deadline)
        external
        nonReentrant
        returns (uint128 liquidityAdded)
    {
        bytes32 pairId = _pairId2(tokenA, tokenB, fee);
        VaultPair storage vp = vaultPairs[pairId];
        require(vp.exists, "Vault: pair not registered");
        require(vp.tokenId != 0, "Vault: no position yet");

        (uint256 fee0, uint256 fee1) = positionManager.collect(
            vp.tokenId, address(this), type(uint128).max, type(uint128).max
        );

        uint256 skim0 = (fee0 * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 skim1 = (fee1 * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
        if (skim0 > 0) IERC20(vp.token0).safeTransfer(treasury, skim0);
        if (skim1 > 0) IERC20(vp.token1).safeTransfer(treasury, skim1);

        // Keeper incentive: whoever triggers harvest() (bot or human) earns a
        // small cut of the fees they just realized. Without this there's no
        // reason for anyone to call harvest proactively, and compounding
        // would only happen whenever a depositor's own deposit/withdraw
        // happened to also need it.
        uint256 reward0 = (fee0 * HARVEST_CALLER_REWARD_BPS) / BPS_DENOMINATOR;
        uint256 reward1 = (fee1 * HARVEST_CALLER_REWARD_BPS) / BPS_DENOMINATOR;
        if (reward0 > 0) IERC20(vp.token0).safeTransfer(msg.sender, reward0);
        if (reward1 > 0) IERC20(vp.token1).safeTransfer(msg.sender, reward1);

        // Sweep the vault's full free balance (this harvest's net fees plus
        // any dust left over from a previous harvest) back into the position.
        uint256 amount0Desired = IERC20(vp.token0).balanceOf(address(this));
        uint256 amount1Desired = IERC20(vp.token1).balanceOf(address(this));
        if (amount0Desired == 0 && amount1Desired == 0) {
            emit Harvest(pairId, msg.sender, skim0, skim1, reward0, reward1, 0);
            return 0;
        }

        _approveIfNeeded(vp.token0, amount0Desired);
        _approveIfNeeded(vp.token1, amount1Desired);
        liquidityAdded = _liquidityForAmounts(vp, amount0Desired, amount1Desired);
        require(liquidityAdded >= minLiquidityOut, "Vault: harvest slippage");
        positionManager.increaseLiquidity(vp.tokenId, liquidityAdded, 0, 0, deadline);
        vp.liquidity = _liveLiquidity(vp.tokenId); // resync from ground truth, not += liquidityAdded

        emit Harvest(pairId, msg.sender, skim0, skim1, reward0, reward1, liquidityAdded);
    }

    // ── Views ────────────────────────────────────────────────────────────

    function getVaultPairId(address tokenA, address tokenB, uint24 fee) external pure returns (bytes32) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        return _pairId(token0, token1, fee);
    }

    /// @notice Frontend note: this deliberately does NOT return a USD/token
    ///         value estimate — turning `liquidity` + grid range into token
    ///         amounts needs full sqrt-price math. The Archiel frontend
    ///         already has this exact pattern for regular V3 LP positions
    ///         (a callStatic.decreaseLiquidity preview) — reuse it here by
    ///         previewing a decrease of `liquidity * sharePctBps / 10000`.
    function getVaultPosition(address user, address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (
            uint256 shares,
            uint256 totalShares,
            uint256 sharePctBps,
            uint256 tokenId,
            uint128 liquidity,
            int24 gridLower,
            int24 gridUpper
        )
    {
        bytes32 pairId = _pairId2(tokenA, tokenB, fee);
        VaultPair storage vp = vaultPairs[pairId];
        shares = shareOf[pairId][user];
        totalShares = vp.totalVaultShares;
        sharePctBps = totalShares > 0 ? (shares * BPS_DENOMINATOR) / totalShares : 0;
        tokenId = vp.tokenId;
        liquidity = tokenId != 0 ? _liveLiquidity(tokenId) : 0; // live read, not the cached vp.liquidity
        gridLower = vp.gridLower;
        gridUpper = vp.gridUpper;
    }

    // ── Internal helpers ─────────────────────────────────────────────────

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _pairId(address token0, address token1, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1, fee));
    }

    function _pairId2(address tokenA, address tokenB, uint24 fee) internal pure returns (bytes32) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        return _pairId(token0, token1, fee);
    }

    function _approveIfNeeded(address token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 current = IERC20(token).allowance(address(this), address(positionManager));
        if (current < amount) {
            IERC20(token).forceApprove(address(positionManager), type(uint256).max);
        }
    }

    /// @dev Converts desired token amounts into a liquidityDelta for a
    /// registered pair, using the pool's current sqrtPriceX96 and the
    /// pair's fixed grid range. This mirrors exactly what
    /// ArchielV3PositionManager.mint() computes internally — needed here
    /// because increaseLiquidity() on the real contract takes a liquidity
    /// amount directly, not desired token amounts (see the interface note
    /// above). Amounts are capped by whichever token is the binding
    /// constraint, same as a normal mint — any leftover dust is refunded to
    /// the caller by deposit()'s existing refund logic.
    function _liquidityForAmounts(VaultPair storage vp, uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
        returns (uint128 liquidity)
    {
        address pool = factory.getPool(vp.token0, vp.token1, vp.fee);
        (uint160 sqrtPriceX96, , , ) = IArchielV3PoolMinimal(pool).slot0();
        uint160 sqrtRatioAX96 = TickMathLocal.getSqrtRatioAtTick(vp.gridLower);
        uint160 sqrtRatioBX96 = TickMathLocal.getSqrtRatioAtTick(vp.gridUpper);
        liquidity = LiquidityAmountsLocal.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
    }

    /// @dev Reads the position's *actual* on-chain liquidity instead of trusting
    ///      the vault's own tracked `vp.liquidity`. increaseLiquidity() on the
    ///      position manager is callable by anyone with a valid tokenId — it
    ///      doesn't check ownership — so a third party can add liquidity to the
    ///      vault's position from outside the vault entirely. If deposit/
    ///      withdraw/harvest/rebalance only ever updated `vp.liquidity` by
    ///      addition/subtraction, that kind of external top-up would silently
    ///      drift the vault's internal accounting away from the real position,
    ///      slowly skewing how much liquidity each depositor's shares are
    ///      worth. Grounding every liquidity-changing call in a fresh read
    ///      keeps shares correctly priced regardless of what happens outside
    ///      the vault's own calls.
    function _liveLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (, , , liquidity, , , , ) = positionManager.positionsById(tokenId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
