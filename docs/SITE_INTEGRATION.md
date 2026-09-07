# PUNZ — site integration handoff

Goal: fold everything that lives on **live.punzrh.com** into **punzrh.com** so there is one website. live.punzrh.com stays up as the
data backend (JSON endpoints) and as a plain fallback; punzrh.com becomes the only thing people are sent to.

Everything below is public. No keys, no secrets, nothing to hide.

---

## 1. What the project is (copy source of truth)

**One-liner.** PUNZ is a meme coin on Robinhood Chain whose trading fees short PONS. You buy the coin, the coin does the rest.

**How it works, plain.** Every PUNZ trade pays a 3% fee. Every minute a keeper harvests it. The ETH half goes into a short on PONS, the
PUNZ half is burned. Nobody takes a cut.

**Two shorts, same fees, same redeem button.**
- **v1 – the vault.** An on-chain perpetual vault on Robinhood Chain with a long side and a short side. sPONS is the short side token.
  PUNZ's fees buy sPONS and hold it in the Backing contract. Settles instantly, no liquidation. Any holder can burn PUNZ and take their
  pro-rata sPONS right away. This is the floor.
- **v2 – the real short.** A contract (LighterBacking) owns an account on **Robinhood Lighter** (a perp exchange on Robinhood Chain) and is
  short PONS on the order book at 1.5x. Lighter only pays withdrawals to the contract, and the key needed to move funds elsewhere does not
  exist. Any holder can burn PUNZ to force-close their share of the short on-chain and get paid in USDG.
- Describe them as working **together**. Never describe v1 as worse, fake, or synthetic in a negative way.

**Boost (optional).** Anyone can add ETH + PUNZ as liquidity through FeeFeeder3. They keep their principal and can withdraw any time;
every fee that liquidity earns goes to the v2 short (ETH) and burn (PUNZ). Call it "Boost the short with your liquidity". Do not lead with
the contract name.

**Copy rules.**
- Do not mention any other project or competitor by name.
- Do not claim "first meme coin with a PONS short". The accurate claim: the short is held by a contract nobody controls, and holders can
  force-close their share themselves.
- Do not claim "PONS dumps → PUNZ pumps". Say: PONS down → the backing per PUNZ goes up.
- Always include: "Not advice. The short can lose money if PONS rises. Check it, don't trust it."
- Credit the idea to @loraclexyz (tweet 6 Sep 2026). Nobody else.

---

## 2. Addresses (Robinhood Chain, chainId 4663 / 0x1237)

| Thing | Address |
|---|---|
| PUNZ token | `0x03a0e8FC8b5485CF6F66B6264F1fE295F4C24896` |
| Vault v1 (PonsPerpPool, renounced) | `0xd1C0B5E2eA749F738da9E4c13858b4fEb0f6C39D` |
| sPONS (short token) | `0x7c5e0547bcCdd474B3922188AB8d91d32a10DEf9` |
| lPONS (long token) | `0xeD99562d92091aE7fc1B6aacA8f1A340ba01391a` |
| Backing v1 | `0xfCD2b6a649b4Bbf417D24B5A743D1A067cC3A348` |
| Locked LP (V4Launch) | `0xE543a5fe1Ebe504FdDdD0D41C8B59D3937c73e90` |
| sPONS/ETH market (SeedPool) | `0x4e74795123530fa20EbCDCc6594DfeF389C4d766` |
| **LighterBacking v2** | `0x886AE5d94E5b85A0FA40bA766D1A4689F53d1d39` — Lighter account **23662** |
| **FeeFeeder3 (boost, current)** | `0xb7D53B0Adac72cAA6eb94b39aa5C81DAEbCec17E` |
| FeeFeeder2 | BRICKED, never link it |
| FeeFeeder (original, locked) | `0x40f0e263f6C3E7079E1897941fc27490734c55E7` |
| PONS | `0x39dBED3a2bd333467115dE45665cC57F813C4571` |

RPC: `https://rpc.mainnet.chain.robinhood.com` · Explorer: `https://robinhoodchain.blockscout.com` (also rh-scan.com)
Source: `https://github.com/PunzRH/punzrh` · Feed: `https://t.me/PunzRh` · X: `https://x.com/PunzRH`

---

## 3. Live data endpoints (CORS `*`, no auth, no cache)

### `GET https://live.punzrh.com/metrics` — one JSON object, refreshed every 30 s

| field | meaning | unit |
|---|---|---|
| `tokenAddress` | PUNZ | address |
| `marketPriceEth` | PUNZ price from the pool | ETH per PUNZ |
| `ethUsd` | ETH price from the on-chain WETH/USDG pool | USD |
| `totalSupply` | PUNZ supply (falls with burns) | PUNZ |
| `burned` | total PUNZ burned by fee harvests | PUNZ |
| `feesToShortEth` | ETH fees converted into the v1 short since launch | ETH |
| `ponsPriceEth` | PONS price (vault oracle, 2-min TWAP) | ETH |
| `shortNavEth` | sPONS NAV | ETH per sPONS |
| `longNavEth` | lPONS NAV | ETH per lPONS |
| `sponsBacking` | sPONS held in Backing v1 | sPONS |
| `backingPerPunzEth` | v1 floor: what 1 PUNZ redeems for | ETH per PUNZ |
| `vaultOwner` | always 0x0 (renounced) | address |
| `v2_short_pons` | v2 short size as mirrored on-chain | PONS |
| `v2_collateral_usdg` | USDG deposited by the contract | USDG |
| `v2_equity_usdg` | on-chain estimate of v2 equity | USDG |
| `v2_floor_usdg_per_punz` | v2 floor per PUNZ | USDG per PUNZ |
| `v2_eth_waiting` | ETH on LighterBacking not yet deposited | ETH |
| `lighter_account` | the contract's Lighter account index | 23662 |
| `lighter_position_pons` | live position from the exchange (negative = short) | PONS |
| `lighter_entry` | avg entry price | USDG |
| `lighter_upnl` | unrealized PnL | USDG |
| `lighter_liq` | liquidation price | USDG |
| `lighter_collateral` | live collateral | USDG |
| `ff_eth_fed` | ETH fees sent to v2 by the boost positions (both feeders) | ETH |
| `ff_punz_burned` | PUNZ burned by the boost positions | PUNZ |
| `ff_in_range` | boost position currently earning | bool |
| `ff_total_shares` | boost shares outstanding | shares |
| `updatedAt` | unix seconds | s |

Derived numbers to show: market cap = `marketPriceEth × ethUsd × totalSupply`; PUNZ USD = `marketPriceEth × ethUsd`; v1 floor USD per
1M PUNZ = `backingPerPunzEth × ethUsd × 1e6`; v2 floor USD per 1M PUNZ = `v2_floor_usdg_per_punz × 1e6`; v2 notional USD =
`|lighter_position_pons| × mark` (mark ≈ `lighter_entry + lighter_upnl / lighter_position_pons`).

For the **position card prefer the `lighter_*` fields** (they come straight from the exchange API); `v2_*` are the on-chain mirror.

### `GET https://live.punzrh.com/events` — array of the last 150 on-chain events, newest last

Every item has `kind`, `msg` (ready-to-display text), `t` (unix s), `block`, `tx`. Extra fields per kind:

| kind | extra fields | meaning |
|---|---|---|
| `buy` | `eth`, `coin` | PUNZ bought on the pool |
| `sell` | `eth`, `coin` | PUNZ sold |
| `harvest` | `eth_instant`, `eth_vault`, `spons`, `burned` | fee harvest → sPONS + burn |
| `burn` | `coin` | PUNZ burned |
| `rebalance` | `pons`, `long`, `short` | vault repriced (every ~60 s) |
| `spons_buy` / `spons_sell` | `eth`, `spons` | sPONS market trades (Backing buys, peg bot sells) |
| `donate` | `spons` | peg-bot profit sent to Backing |
| `redeem` | `coin`, `spons` | holder burned PUNZ for sPONS |
| `commit` | `side`, `eth` | vault mint/burn commit |

Link each row to `https://rh-scan.com/tx/<tx>`.

### `GET https://live.punzrh.com/data` — history array (30-s snapshots, last 2000)

Same field names as the internal snapshot: `t, pons, nav_s, nav_l, long_bal, short_bal, epochs, ethpool (PUNZ price ETH), floor,
backing_spons, eth_to_short, burned, eth_usd, supply, v2_*, ff_*, lighter_*`. Use it for charts: PONS vs sPONS NAV vs PUNZ floor,
normalized to 100 at the first point.

### `GET https://live.punzrh.com/stats.json` — protocol stats rebuilt from chain events since launch (CORS `*`)

`split` (holders 100 / creator 0 / treasury 0 / keeper 0), `volume` {eth, usd, buys, sells}, `fees` {generated_eth, generated_coin,
delivered_to_v1_short_eth, delivered_to_v2_short_eth, coin_burned, burned_pct_of_supply}, `backing` {v1_spons, v1_value_eth/usd,
v2_collateral_usdg, v2_short_pons, v2_entry, v2_mark, v2_notional_usd, v2_upnl_usdg, v2_liq, total_backing_usd, supply, market_cap_usd},
`redemptions` {count, coin, spons_paid}, `daily[]` and `hourly[]` (last 72 h) with {t, volume_eth, buy_eth, sell_eth, trades,
fees_eth_to_short, fees_coin_burned, burned, delivered_eth, redeems}. Rendered reference page: https://live.punzrh.com/stats.

### Exchange-side truth (no CORS guarantees, show as a link)

`https://api.rh.lighter.xyz/api/v1/account?by=index&value=23662` → `accounts[0].collateral`, `positions[]` (market_id 44 = PONS-PERP;
`sign` -1 = short, `position`, `avg_entry_price`, `unrealized_pnl`, `liquidation_price`).

---

## 4. Wallet actions (what the /vault page does; copy this, no backend needed)

All calls are plain `eth_sendTransaction` from the user's wallet. Chain `0x1237`; add the chain with RPC above, symbol ETH, explorer
`https://rh-scan.com`. Encodings: `pad(x)` = 32-byte hex, amounts in wei (×1e18). Read calls are `eth_call` to the RPC.

| Action | Target | Calldata | Value | Notes |
|---|---|---|---|---|
| Redeem PUNZ for sPONS | PUNZ | `0xdb006a75` + pad(amount) | 0 | **Burns PUNZ.** Confirm dialog required. Never pre-fill the full balance. |
| Go long (mint lPONS) | Vault | `0x4f60dbaf` + pad(0) | ETH | two-step: claim ~2–3 min later |
| Go short (mint sPONS) | Vault | `0x4f60dbaf` + pad(1) | ETH | same |
| Burn lPONS / sPONS for ETH | Vault | `0xc3054d94` + pad(side) + pad(shares) | 0 | needs ERC-20 approve of that token to the vault first |
| Claim matured commit | Vault | `0xc3490263` + pad(id) + epoch(32 bytes) | 0 | `epoch` from `claimableEpoch(id)` = `0x074bb1ec`+pad(id); ready when ≠ max uint |
| Boost: approve PUNZ | PUNZ | `0x095ea7b3` + pad(FeeFeeder3) + pad(max) | 0 | once |
| Boost: add | FeeFeeder3 | `0x1003e2d2` + pad(punzAmount) | ETH | ≈ equal value works best; what doesn't fit stays as the depositor's idle principal (not refunded, still withdrawable) |
| Boost: withdraw | FeeFeeder3 | `0x2e1a7d4d` + pad(shares) | 0 | shares from `shares(addr)` = `0xce7c2ac2`+pad(addr) |
| v2 redeem (burn PUNZ, force-close share) | LighterBacking | `redeem(uint256 amount, uint256 maxBuyPriceTicks)` | 0 | advanced; not on the page yet, link to Blockscout write tab |

Reads used for the stats strip: vault `sharePriceWei(uint8)` = `0x6b6dfd3c`+pad(side); `longBal()` `0xf1e2dbbf`; `shortBal()`
`0xa3af9574`; Backing `sponsBacking()` `0x48f84dc5`; `floorWeiPerToken()` `0xd438686f`; FeeFeeder3 `liquidity()` `0x1a686502`,
`totalEthFed()` `0xdc937817`, `totalPunzBurned()` `0xfbddbf94`, `totalShares()` `0x3a98ef39`, `principalOf(addr)` `0x61e20a1c`+pad(addr)
→ (eth, punz).

UX rules from the existing page: every burning action shows a confirm dialog with the exact amount and what comes back; amount boxes
default to 0; the page never asks for a token approval except for the token being burned or boosted; a "Don't trust this page?" box
links the Blockscout write tabs so people can do everything without the site.

---

## 5. Pages to merge (what live.punzrh.com has today)

- **/** Home. Big number = market cap. Stats strip (PUNZ price, burned, supply, ETH→short, v1 floor, v2 floor). **OPEN POSITION**
  card for v2 (short size, entry, mark, uPnL, liquidation, collateral, "held by contract", link to the Lighter API). v1 VAULT SHORT card
  (sPONS backing, worth in ETH, sPONS/lPONS since launch, long/short balances). Live feed (from /events). Buttons: Feed the short →
  /vault, Redeem PUNZ → /vault, Contract → explorer.
- **/live** The machine: an animated flow (trade → fee → harvest → short/burn) plus the same feed.
- **/vault** Wallet page: connect, stats, long/short mint+burn, claim, redeem PUNZ, boost (add/withdraw). Keep this page's exact
  behaviours (section 4).
- **/how** The full explainer, 11 sections. Reuse its text as the "How it works" page. Current text:
  `https://live.punzrh.com/how` (view-source is fine; placeholders already substituted).
- **/charts** Old status page (PONS vs sPONS vs lPONS vs floor, normalized). Optional.

Style: the current pages are dark, monospace numbers, green for "up/backing", red for short/burn actions, no gradients, no stock photos.
punzrh.com's own style wins; keep the numbers big and the words few.

---

## 6. What runs behind it (so the site never has to)

A keeper wallet (`0xfCBa0Dcb1668f94fF1cef112D04a4D2F3A537ae5`) calls the public functions every minute: vault `rebalance()`, Backing
`harvest()`, peg-bot trades on the sPONS market, FeeFeeder2 `harvest()`, LighterBacking `fund()` + the Lighter market order + `sync()` +
`settle()`. All of these are permissionless; if the keeper stops, anyone can call them and nothing is trapped. Telegram channel
t.me/PunzRh posts the same events. Everything is served from the keeper host through a Cloudflare tunnel at live.punzrh.com.
