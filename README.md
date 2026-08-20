# Archiel Finance — Smart Contracts

Official smart contract source code for **Archiel Finance**, a DeFi protocol on Arc Network offering swap, concentrated liquidity pools, staking, lending, futures/perpetuals, and cross-chain FX swap.

🔗 App: 🔗 App: [archielfinance.xyz](https://archielfinance.xyz/)

> ⚠️ This repository contains contracts currently deployed on **Arc Testnet**. Addresses and contracts may change during active development. Always verify the deployed address against the live app before interacting with any contract directly.
>
> 🆕 `ArchielV3` (concentrated liquidity AMM) and `ArchielVaultV3.sol` were deployed recently (within the past week) and are the current active pool/vault implementations, superseding `ArchielPools.sol` and earlier vault versions.

---

## Repository Structure

```
contracts/
├── core/
│   ├── ArchielFutures.sol
│   ├── ArchielFxEscrow.sol           # 🔧 In development (RedStone oracle migration)
│   ├── ArchielFxToken.sol
│   ├── ArchielPerp.sol
│   ├── ArchielPools.sol              # Legacy name, only futuresReserve module active — see note below
│   ├── ArchielProxy.sol
│   ├── ArchielStakingV3.sol
│   ├── ArchielToken.sol
│   ├── ArchielVaultV3.sol            # Current active vault (deployed ~1 week ago)
│   ├── ArchielV3/                    # Concentrated liquidity AMM (deployed ~1 week ago)
│   │   └── contracts/
│   │       ├── core/                 # Factory, Pool
│   │       ├── interfaces/
│   │       ├── libraries/            # Math, tick, swap libraries
│   │       └── periphery/            # Position Manager, Router, Quoter, NFT Descriptor
│   └── RegarToken.sol                # Legacy name — STILL ACTIVE, see note below
├── Lending/
│   ├── ArchielLendingBorrow_v3.sol   # Lending & borrowing market
│   └── TestnetERC20.sol              # Testnet mock token for testing
├── deprecated/                       # No longer in use — kept for historical reference only
│   ├── RegarSwapPoolV2.sol
│   └── RegarVault.sol
├── interfaces/                       # Shared contract interfaces
├── scripts/                          # Deployment scripts
├── tests/                            # Contract test suites
├── flattened/                        # Flattened source for verification on explorers
└── .deploys/pinned-contracts/        # Pinned deployment snapshots by block
```

---

## Contract Status

| Contract | Status | Notes |
|---|---|---|
| `ArchielV3Factory.sol` / `ArchielV3Pool.sol` | ✅ Active | Core concentrated liquidity AMM |
| `ArchielV3PositionManager.sol` / `ArchielV3SwapRouter.sol` / `ArchielV3Quoter.sol` | ✅ Active | V3 periphery contracts |
| `ArchielLendingBorrow_v3.sol` | ✅ Active | Lending market |
| `ArchielStakingV3.sol` | ✅ Active | Multi-asset staking, per-second APR accrual |
| `ArchielFutures.sol` / `ArchielPerp.sol` | ✅ Active | Futures / perpetuals trading |
| `ArchielPools.sol` (on-chain: `ArchielLiquidityPool`) | ⚠️ Partially active (legacy) | AMM swap/LP functionality is **deprecated**, superseded by ArchielV3 pools. Only the `futuresReserve` module inside this contract is still active — it holds trader margin/collateral for `ArchielFutures.sol` / `ArchielPerp.sol`. See note below. |
| `ArchielFxEscrow.sol` | 🔧 In active development | Migrating from Pyth-only to hybrid oracle (Pyth / RedStone / Chainlink) |
| `ArchielFxToken.sol` | ✅ Active | FX-pegged synthetic asset |
| `ArchielVaultV3.sol` | ✅ Active | Protocol vault |
| `ArchielToken.sol` | ✅ Active | Native protocol token |
| `RegarToken.sol` | ✅ Active (legacy name) | Original token contract from before the rebrand to Archiel Finance. Still in active use — **not deprecated**. |
| `RegarSwapPoolV2.sol` | ❌ Deprecated | Moved to `/deprecated`. Superseded by ArchielV3 pools. No longer in use. |
| `RegarVault.sol` | ❌ Deprecated | Moved to `/deprecated`. Superseded by `ArchielVaultV3.sol`. No longer in use. |

> Contracts in `/deprecated` are kept for historical reference and audit trail only. They are not called by the live app and should not be interacted with.

---

## Note on `ArchielPools.sol` (`ArchielLiquidityPool`)

Deployed at `0xcAdDE50c774B8D5314e4859fc9711AB28026B3f8` on Arc Testnet.

This contract was originally built as a full AMM liquidity pool (deposit, swap, withdraw, LP shares — replacing an earlier buggy pool where `withdrawLiquidity()` always reverted). It also contains a separate internal ledger, `futuresReserve`, purpose-built to hold trader margin/collateral for Futures/Perpetuals trading, kept isolated from the swap-pair reserves so trader PnL never affects swap pricing or LP principal.

**Current status:** the swap/LP side of this contract is no longer the primary liquidity venue — that role has moved to the ArchielV3 concentrated liquidity pools. **This contract is currently used only as the reward/margin pool for Perpetuals trading**, via its `futuresReserve` module — holding user-deposited margin and reward funds for `ArchielFutures.sol` / `ArchielPerp.sol`. The on-chain contract name (`ArchielLiquidityPool`) reflects its original design and cannot be changed post-deployment.

---

## Oracle Architecture (FX Swap)

`ArchielFxEscrow.sol` supports multiple oracle sources per token via an `oracleSource[token]` selector:

- **Pyth Network** — used for Futures/Lending price feeds
- **RedStone** — primary oracle for FX swap (`redstone-primary-prod`, `uniqueSignersCount: 3`)
- **Chainlink** — fallback source, token-dependent

This migration is in progress due to Pyth's paid API requirement effective August 18, 2026.

---

## Deployed Addresses (Arc Testnet)

**ArchielV3 (Concentrated Liquidity AMM)** — deployed ~1 week ago

| Contract | Address |
|---|---|
| Pool (implementation) | `0x307D80949343FA97F8C771DFBafcF4AcD42B3E2B` |
| Factory | `0xE0C9687D29f8e85d1B53A231d22b52aBB4eE880B` |
| SwapRouter | `0xF687B11678B0Eb10Be1408623cE0512927559DE5` |
| Quoter | `0x003Ecf46001d69222D80D5aB128522907A3fBAe6` |
| NFTDescriptor | `0x037BE8C425D77DB955444988002D0f2D4e0f7766` |
| PositionManager | `0x6f84C45A91557A46015a2272FDF80839f2fb77Cc` |
| VaultV3 | `0x0aa13ba5Fd25F0695AEd61264A4842Fa00B707bd` |

> ⚠️ Double-check every address above against the live app before interacting directly — always verify via the block explorer that the deployed bytecode matches the source in this repo.

**FX Swap**

| Contract | Address | Status |
|---|---|---|
| ArchielFxEscrow | `0xbf0a0bFFC8EE69662bA6Fd24303CA141105dCE55` | 🔧 Current live version — being migrated from Pyth-only to hybrid oracle (Pyth / RedStone / Chainlink). Address will be updated here once the new version is deployed. |
| ArchielFxToken — Archiel IDR (IDRC) | `0x63f4b175CC0d9B5E1DAC459e93E375479Df60150` | One of the FX-pegged tokens deployed via `ArchielFxToken.sol`. More FX tokens may be deployed as additional currencies go live — this table will be updated as they are added. |
| ArchielFxToken — Archiel Synthetic Silver (sXAG) | `0x12E7D219ceE9DDa3294CC7A58b3475E53AB04011` | FX/commodity-pegged synthetic token |
| ArchielFxToken — Archiel JPY (JPYC) | `0xF2795D69dFB1C1Be8B034c18570cD4672a1e541d` | FX-pegged synthetic token |
| ArchielFxToken — Archiel AUD (AUDC) | `0x68d4813a70d1eAb1949f70Ae503e0d51Ba9563Dc` | FX-pegged synthetic token. Note: `AUD_FX` is marked `onchainSwapDisabled: true` on the RedStone feed specifically — AUD swap works normally when routed via the Pyth oracle source. |
| ArchielFxToken — Archiel GBP (GBPC) | `0xcb0a04055914de60EcDAC1e420f4D851753De3b3` | FX-pegged synthetic token |
| ArchielFxToken — Archiel Synthetic Gold (sXAU) | `0xf876cD0f025baDfb49602BDd8feEa9Fca05cCb0c` | FX/commodity-pegged synthetic token |

**Staking**

| Contract | Address |
|---|---|
| ArchielStakingV3 | `0x3C08aDdBf5afd91459686F15B9BF57D6106Bac9a` |

**Futures / Perpetuals**

| Contract | Address | Notes |
|---|---|---|
| ArchielProxy | `0x1efA884d6C8835B9516cC79337867726e59d198D` | Upgradeable proxy — current implementation is `ArchielPerp.sol`. Interact via this proxy address, not the implementation directly. |
| ArchielFutures | `0x1dE8FC610DA4744832C066F11E9b657Ae9a7193B` | Standalone Futures contract |
| ArchielLiquidityPool (`ArchielPools.sol`) | `0xcAdDE50c774B8D5314e4859fc9711AB28026B3f8` | Legacy name — currently used only as the reward/margin pool for Perp trading, not for swap/LP. See note below. |

**Lending**

| Contract | Address |
|---|---|
| ArchielLendingBorrowV3 | `0x7Cb02904cFB93c5608e042128C2Dd519EEf51fe6` |

**Token**

| Contract | Address |
|---|---|
| ArchielToken (ARCL) | `0x363b48c34A062712581F925d635a8442469600Ee` |
| RegarToken (REGAR) | `0x18C6B42c586A49c18bf151cf9944f4fDCa6FE61D` |

---

## Deployment

Deployment scripts are in `/scripts`. Pinned deployment records (contract address ↔ block number) are tracked under `/.deploys/pinned-contracts/`.

## Disclaimer

This repository is provided for transparency and audit purposes. It does not constitute financial advice. Always DYOR (do your own research) before interacting with any smart contract.
