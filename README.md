# PUNZ — a meme coin backed by a tokenized PONS short

Live on Robinhood Chain (chainId 4663). Everything in this repo is deployed, verified, and running with no admin keys.

- **How it works (full explainer): https://live.punzrh.com/how**
- Site: https://punzrh.com · Live status: https://live.punzrh.com · Machine view: https://live.punzrh.com/live · Vault UI: https://live.punzrh.com/vault
- X: https://x.com/PunzRH · Telegram feed (written by the contracts): https://t.me/PunzRh

## What it does

1. **PonsPerpPool** (`src/PonsPerpPool.sol`) — an on-chain perpetual pool for PONS. One pool of ETH with a LONG side and a SHORT side.
   Every 30 seconds anyone can call `rebalance()`: it reads a 2‑minute TWAP from PONS's own Uniswap v3 pool and moves ETH from the
   losing side to the winning side. Shares of each side are ERC‑20s: **sPONS** (short) and **lPONS** (long). Mint with ETH, burn for ETH,
   at NAV, after a full TWAP window (two‑step commit/claim so the lagging oracle can't be front‑run). No liquidations, no funding, no operator.
   Owner is `0x0` (fee locked at 0 forever).
2. **PUNZ** (`src/PoonsToken.sol`) — a plain ERC‑20, no owner, fixed 1B supply, trades on a hookless Uniswap v4 pool quoted in ETH.
   The liquidity is a single‑sided locked position in **V4Launch** (`src/V4Launch.sol`); its only owner function is `collectFees()`, owned by Backing.
3. **Backing** (`src/Backing.sol`) — `harvest()` (permissionless) collects the pool's 3% fees: the ETH half buys sPONS (on the sPONS/ETH
   market if within 3% of NAV, else minted from the vault at NAV), the PUNZ half is burned. `PUNZ.redeem(amount)` burns PUNZ and pays the
   holder their pro‑rata share of the sPONS held here. That is the floor.
4. **SeedPool** (`src/SeedPool.sol`) — the sPONS/ETH reference market. A keeper (`keeper/peg_keeper.py`) keeps it within 1% of NAV and
   sends its profit into Backing.

## Deployed addresses (Robinhood Chain)

| Contract | Address |
|---|---|
| PUNZ | `0x03a0e8FC8b5485CF6F66B6264F1fE295F4C24896` |
| Vault (PonsPerpPool) | `0xd1C0B5E2eA749F738da9E4c13858b4fEb0f6C39D` |
| sPONS | `0x7c5e0547bcCdd474B3922188AB8d91d32a10DEf9` |
| lPONS | `0xaD19306aB3b613D49BaC7C52bEe3eD64A184F5d2` |
| Backing | `0xfCD2b6a649b4Bbf417D24B5A743D1A067cC3A348` |
| Locked LP (V4Launch) | `0xE543a5fe1Ebe504FdDdD0D41C8B59D3937c73e90` |
| sPONS/ETH SeedPool | `0x4e74795123530fa20EbCDCc6594DfeF389C4d766` |

Verified source: https://robinhoodchain.blockscout.com/address/0xd1C0B5E2eA749F738da9E4c13858b4fEb0f6C39D?tab=contract (and the others).

## Interact without trusting any website

All functions are public. On Blockscout, open the contract → **Write contract** → connect wallet:

- Go long: vault `commitMint(0)` with ETH → wait ~2–3 min → `claim(id, claimableEpoch(id))`
- Go short: vault `commitMint(1)` (this is what PUNZ fees do every minute)
- Exit: vault `commitBurn(side, shares)` → claim ETH
- Redeem PUNZ: PUNZ `redeem(amount)` → sPONS paid instantly from Backing


## Backing v2 — a real PONS short on Robinhood Lighter, custodied by a contract (live 7 Sep 2026)

| Contract | Address |
|---|---|
| LighterBacking (v2) | `0x886AE5d94E5b85A0FA40bA766D1A4689F53d1d39` — Lighter account 23662 |
| **FeeFeeder3 (boost, current)** | `0xb7D53B0Adac72cAA6eb94b39aa5C81DAEbCec17E` — ±49% range, fork-tested against the FeeFeeder2 failure (`test/FeeFeeder3.t.sol`) |
| FeeFeeder2 (**BRICKED, do not use**) | `0x9B81c0577cCEBfef2920fd061539CDc6235377ef` — recenter() re-added zero liquidity after a one-sided range exit; all functions revert; 1.11 ETH of the developer's principal is stuck. Post-mortem in docs/. |
| FeeFeeder (original, locked LP → v2) | `0x40f0e263f6C3E7079E1897941fc27490734c55E7` |

- **Custody is trustless:** all collateral sits in the contract's own Lighter account. Lighter's bridge only pays withdrawals to the account's L1 owner (the contract), and L2 transfers to other accounts require the owner's L1 private key, which does not exist.
- **Opening needs a key:** Lighter's L1 `createOrder` is reduce-only, so the short is opened by a keeper holding a trading API key registered once on the account (`registerKey`). That key can trade and nothing else; worst case is bad trades, never theft.
- **Exit is forced:** `redeem(punz)` burns PUNZ, L1-force-closes that share of the short (reduce-only IOC, no key needed) and withdraws that share of the estimated equity. USDG lands on the contract in ~1–7 min; `settle()` pays claims in order.
- **Feed:** `FeeFeeder3` is a concentrated liquidity position in the PUNZ/ETH pool. Anyone can `add(punz)` with ETH and receives shares; `withdraw(shares)` returns that slice of the principal at any time. Depositors never receive the fees: on every harvest, add and withdraw the ETH fees go to LighterBacking (→ USDG → the short) and the PUNZ fees are burned. `recenter()` (anyone, 20-min cooldown) re-centres the range when price walks out of it, placing a one-sided range next to the price when only one token is left (the bug that bricked FeeFeeder2: it re-added zero liquidity and every function reverted, locking 1.11 ETH of the developer's principal). The original `FeeFeeder` (locked, no withdraw) still runs alongside it.
- Rehearsal contracts (the $20 experiments): `src/LighterProbe.sol`, `src/LighterProbe2.sol`. Robinhood Lighter API: `https://api.rh.lighter.xyz`.

## Build & test

```
forge install   # openzeppelin-contracts, v4-core, forge-std
forge test      # includes fork tests against the live chain (RH_RPC_URL) and the crash demo: test/PunzCrashDemo.t.sol
```

## Layout

- `src/` contracts · `test/` Foundry tests · `script/` deploy scripts · `deployment_real.json` live addresses
- `keeper/` the off‑chain keepers (rebalance/harvest/peg/dashboard/telegram feed) — all call permissionless functions
- `ui/` the vault and live pages (single HTML files, direct wallet calls, no backend) and the Cloudflare metrics function

No audit yet. Read the code; it's short.
