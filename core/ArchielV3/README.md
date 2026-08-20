# Archiel V3 — Concentrated Liquidity AMM

Full V3-style DEX suite for Archiel Finance (Arc Testnet), built from scratch
(no forked/copied source) to mirror the concentrated-liquidity model: LPs
provide capital to custom price ranges instead of the full curve, multiple
fee tiers per pair, and NFT-based positions.

## Files

**libraries/**
- `FullMath.sol` — overflow-safe 512-bit mulDiv
- `TickMath.sol` — tick ⇄ sqrtPriceX96 conversion
- `SqrtPriceMath.sol` — token deltas / price movement for a given liquidity
- `SwapMath.sol` — single swap-step math (price target + fee)
- `TickBitmap.sol` — packed initialized-tick lookup
- `LiquidityAmounts.sol` — converts desired token amounts ⇄ liquidity for a range (used by PositionManager for accurate sizing)
- `Oracle.sol` — ring-buffer of cumulative tick observations → on-chain TWAP

**core/**
- `ArchielV3Pool.sol` — the AMM: `initialize`, `mint`, `burn`, `collect`, `swap`, `observe` (TWAP), `setFeeProtocol`/`collectProtocol` (protocol fee cut)
- `ArchielV3Factory.sol` — deploys pools per (token0, token1, fee); default tiers 0.05% / 0.3% / 1%; `owner()` gates protocol-fee admin on pools

**periphery/**
- `ArchielV3SwapRouter.sol` — `exactInputSingle`/`exactOutputSingle` (1 pool) and `exactInput`/`exactOutput` (multi-hop via encoded `path`), plus `Multicall` for batching
- `ArchielV3Quoter.sol` — off-chain single-hop quoting via simulate-and-revert (call with `eth_call`, never send a tx)
- `MinimalERC721.sol` + `ERC721Permit.sol` + `ArchielV3PositionManager.sol` — LP positions as transferable NFTs (mint/increase/decrease/collect/burn), sized with `LiquidityAmounts`, batchable via `Multicall`; `ERC721Permit` adds EIP-712 gasless approval so `permit()` + an action can be one transaction
- `periphery/libraries/Base64.sol`, `StringsMinimal.sol`, `NFTSVG.sol`, `NFTDescriptor.sol` — build `tokenURI()` fully on-chain: animated SVG card (orbiting token dots, pulsing in-range/out-of-range indicator, flowing wave line) + base64 JSON metadata, no off-chain server needed
- `periphery/libraries/Path.sol` — encodes/decodes multi-hop routes as packed (token, fee, token, ...) bytes
- `periphery/libraries/Multicall.sol` — batches several calls into one transaction via delegatecall

## Permissionless by design

Every write function that matters for regular users has no owner/admin gate:
- `Factory.createPool()` — anyone can create a pool for any enabled fee tier.
- `PositionManager.mint()` — anyone can seed the first liquidity in a pool.
- `PositionManager.decreaseLiquidity()` / `collect()` / `burnPosition()` —
  gated only by NFT ownership (`onlyPositionOwner`), so each user can only
  withdraw their own positions, but any user can withdraw theirs without an
  admin's help.
- `SwapRouter` — no gating at all.

Only two functions are owner-gated, and neither blocks normal usage:
`Factory.enableFeeAmount()` (add a new fee tier) and
`Pool.setFeeProtocol()`/`collectProtocol()` (protocol fee cut). Both are
called by whoever deployed the Factory (`factory.owner()`), not by
redeploying anything.

## Integration notes for Archiel frontend

1. **Deploy order (5 contracts now):**
   1. `ArchielV3Factory` — no constructor args
   2. `ArchielV3SwapRouter` — constructor arg: Factory address
   3. `ArchielV3Quoter` — constructor arg: Factory address
   4. `ArchielV3NFTDescriptor` — no constructor args
   5. `ArchielV3PositionManager` — constructor args: Factory address, **then** NFTDescriptor address (in that order)
2. `factory.createPool(tokenA, tokenB, fee)` — fee must be 100, 500, 3000, or
   10000 unless you call `enableFeeAmount` for a custom tier.
3. A pool must be `initialize(sqrtPriceX96)`d before any mint/swap — compute
   `sqrtPriceX96 = sqrt(price) * 2^96` off-chain for the starting price.
4. Your existing V3 swap error (`ArchielSwapQuoterV3: pool not found`) came
   from calling the quoter with a hardcoded `fee: 3000` without checking
   `factory.getPool()` first — with this suite, always resolve the pool
   address via `getPool(tokenA, tokenB, fee)` before quoting, and iterate
   fee tiers if the first doesn't exist.
5. `Quoter.quoteExactInputSingle` must be called as a **read-only call**
   (e.g. `provider.call(...)` / `staticCall`), not sent as a transaction —
   it deliberately reverts to return data cheaply.

## Patch: implementation-lock (mainnet prep)

`ArchielV3Pool` now has a `constructor()` that sets `factory = address(0xdEaD)`
the moment the **implementation** contract itself is deployed. This prevents
anyone from calling `initializeClone()` directly on the implementation
address and registering fake `token0`/`token1`/`fee` on it (EIP-1167 clones
never run this constructor — they only delegatecall into the implementation's
runtime code, so every real clone still starts with `factory == address(0)`
as before). This is a **breaking change to the deployed bytecode** — it
requires redeploying, in order: `ArchielV3Pool` (implementation) →
`ArchielV3Factory(poolImplementation)` → `ArchielV3SwapRouter(factory)` →
`ArchielV3Quoter(factory)` → `ArchielV3PositionManager(factory, nftDescriptor)`.
`ArchielV3NFTDescriptor` has no dependency on Factory/Pool and does **not**
need to be redeployed — reuse the existing deployed address.

## Known simplifications vs. a production-grade V3

- `TickMath.getTickAtSqrtRatio` uses binary search (~21 iterations) instead
  of a bit-magic log2 approximation — correct, but costs more gas. Fine for
  Arc Testnet; worth optimizing before any mainnet use.
- `Oracle.observe`'s binary search over the ring buffer is a straightforward
  implementation, not gas-golfed — fine for testnet TWAP reads.
- Not yet audited — treat as a testnet-ready draft, not production code.

## What was added in this pass

- **`ArchielV3PositionManager.sol` still exceeded 24,576 bytes (33,430) after
  the custom-error fix above — split off `ArchielV3NFTDescriptor.sol` as its
  own deployed contract.** The animated on-chain SVG generation
  (NFTSVG/NFTDescriptor/Base64/StringsMinimal) was itself a large chunk of
  inlined code. Same pattern Uniswap V3 uses — its
  `NonfungibleTokenPositionDescriptor` is a separate contract from
  `NonfungiblePositionManager` for exactly this reason. `PositionManager`
  now takes a second constructor argument (`_nftDescriptor`) and calls
  `nftDescriptor.tokenURI(...)` as an external view call instead of
  building the SVG inline. **This changes the deploy order — see below.**
- **Contract-size fix — custom errors instead of require(string).** After
  the stack-depth fixes above, compiling revealed `ArchielV3Pool.sol`
  (33,607 bytes), `ArchielV3Factory.sol` (39,776 bytes — it embeds Pool's
  full creation bytecode), and `ArchielV3PositionManager.sol` (36,562
  bytes) all exceeded the EIP-170 24,576-byte contract-size limit.
  Optimizer `runs: 1` alone wasn't enough — the fix was replacing every
  `require(cond, "some message")` across the whole call graph (Pool, its
  inlined libraries FullMath/TickMath/SqrtPriceMath/TickBitmap/Oracle/
  SafeERC20Minimal, Factory, PositionManager, and its inlined
  MinimalERC721/ERC721Permit/Path) with a custom error
  (`error X(); if (cond) revert X();`). Each string literal a require()
  message costs is real deployed bytecode; a custom error is just a 4-byte
  selector. Also removed `ArchielV3Pool`'s `onlyFactory` modifier, which
  turned out to be unused dead code. If any contract is still over the
  limit after this, the next lever is Remix's "Revert strings: strip"
  compiler setting (Advanced Configuration), or — for Pool/Factory
  specifically — switching Factory to deploy pools as minimal proxy
  clones instead of full copies.
- **Second stack-depth fix — `ArchielV3PositionManager.sol` and `Oracle.sol`.**
  The first pass (see below) only refactored `ArchielV3Pool.sol`; compiling
  `ArchielV3PositionManager.sol` (which pulls in `Oracle.sol` transitively)
  surfaced the same class of error in `tokenURI()`, `mint()`,
  `increaseLiquidity()`, `decreaseLiquidity()`, `collect()`, and
  `Oracle._getSurroundingObservations()`. `onlyPositionOwner`'s inlined
  ownership checks add a few more live temporaries on top of whatever the
  function body itself holds, which is why even the smaller functions here
  needed splitting once that modifier was added in. Same fix as before —
  split into smaller private helpers (`_buildTokenURI`, `_storePosition`,
  `_increaseLiquidityInternal`, `_decreaseLiquidityInternal`,
  `_collectInternal`, `_binarySearchObservations`) so no function holds too
  many locals live at once. Also dropped an unused `tick` parameter from
  `_getSurroundingObservations` that solc was warning about.
- **`SafeERC20Minimal.sol`** — every token transfer/transferFrom in `Pool`,
  `PositionManager`, and `SwapRouter` now goes through this wrapper instead
  of calling `IERC20Minimal` directly. Plain calls only catch a revert;
  some real-world tokens (older USDT-style contracts, some non-compliant
  tokens found on testnets) return `false` instead of reverting on failure,
  or return no data at all. `SafeERC20Minimal` treats "reverted", "returned
  false", and "not a contract" all as failures, while still accepting
  tokens that return no data (a valid EIP-20 pattern) as success — the
  standard, well-known fix for this class of bug.
- **Decimal support confirmed, not changed** — the core AMM math
  (`TickMath`, `SqrtPriceMath`, `LiquidityAmounts`, `FullMath`, `SwapMath`)
  was already decimal-agnostic by design (Uniswap-V3-style pools operate on
  raw integer token amounts and never assume 18 decimals internally), so
  USDC (6 decimals), ARCL (18), or any other combination already worked
  correctly — confirmed by grepping for any hardcoded decimal assumption
  and finding none.
- **ERC-1271 support in `permit()`** — `ERC721Permit.sol` now verifies
  signatures from smart contract wallets (Safe, Argent, and other
  programmable-authorization wallets), not just EOAs. `permit()`'s signature
  argument changed from separate `(uint8 v, bytes32 r, bytes32 s)` to a
  single `bytes calldata signature`: if the token owner has no code, it's
  verified via `ecrecover` (standard 65-byte EOA signature); if the owner
  IS a contract, it's verified by calling that contract's own
  `isValidSignature()` per EIP-1271, so the wallet's own approval logic
  (multisig threshold, passkey, policy checks) decides validity — the
  same pattern Circle's own Gateway adopted for programmable authorization
  on Arc. This is a pure addition to `permit()`'s interface; nothing else
  changed, and no other contract needed updating.
- **Refactored for stack depth — compiles WITHOUT `viaIR`** — `ArchielV3Pool.sol`'s
  `_modifyPosition()` and `swap()` were the two functions most likely to hit
  `CompilerError: Stack too deep` in Remix's default (non-IR) pipeline, the
  same reason the original Uniswap V3 core is famously hard to compile without
  careful splitting. Both are now broken into several smaller private helper
  functions (`_updateTicksAndSettleFees`, `_settlePositionFees`,
  `_computeLiquidityDeltaAmounts`, `_swapStep`, `_crossTickIfReached`,
  `_settleSwap`) so no single function needs more local variables than the
  EVM's 16-slot stack window allows. `NFTSVG.sol`'s two densest
  `abi.encodePacked()` calls were split the same way. If Remix still reports
  stack-too-deep anywhere, it's safe to enable "via IR" as a fallback — this
  refactor just makes it unnecessary for the common case.
- **0.01% fee tier enabled by default** — `ArchielV3Factory`'s constructor now
  enables fee 100 (tickSpacing 1) alongside 500/3000/10000, since the Archiel
  frontend already offers "0.01% — Stablecoin pairs (USDC/EURC)" as an option.
  Without this, creating that pool would revert with `AV3F: fee not enabled`.
- **TWAP oracle** (`Oracle.sol`) — every swap that moves the tick records a
  cumulative-tick observation; `pool.observe(secondsAgos[])` lets anyone
  derive a time-weighted average price. `increaseObservationCardinalityNext`
  lets you pre-allocate a longer history window.
- **Protocol fee** — `factory.owner()` can call `pool.setFeeProtocol(fee0, fee1)`
  to take a configurable cut (1/4 to 1/10) of LP swap fees, withdrawable via
  `pool.collectProtocol()`.
- **Multi-hop swaps** — `ArchielV3SwapRouter.exactInput`/`exactOutput` walk an
  encoded `path` across several pools in one transaction (e.g. ARCL → USDC → ETH).
- **Multicall** — both the router and the position manager can batch several
  calls (e.g. two swaps, or mint + refund) into a single transaction.
- **Accurate liquidity sizing** — `PositionManager.mint`/`increaseLiquidity`
  now compute liquidity from desired token amounts via `LiquidityAmounts`
  instead of a conservative placeholder.
- **Animated on-chain NFT art** — see below.
- **Gasless approval (`ERC721Permit`)** — `PositionManager.permit(spender, tokenId, deadline, v, r, s)`
  lets a user sign an approval off-chain and combine it with the action
  that needs it (e.g. `collect`) in one `multicall` transaction, no separate
  `approve()` tx first.
