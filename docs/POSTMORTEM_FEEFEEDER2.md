# Post-mortem: FeeFeeder2 bricked (7 Sep 2026)

**What happened.** FeeFeeder2 (`0x9B81c0577cCEBfef2920fd061539CDc6235377ef`) held a ±10% liquidity range in the PUNZ/ETH pool, seeded by the
developer with 0.5 ETH + 12.5M PUNZ. Overnight PUNZ roughly doubled, the price left the range and the position became all ETH, as any
concentrated position does. At 08:29 the keeper called `recenter()`. It removed the liquidity, routed the fees, then computed the new
liquidity from *both* balances with `getLiquidityForAmounts`, which returns the minimum of the two sides. The PUNZ side was zero, so it
added zero liquidity and left 1.111 ETH idle in the contract.

**Why it is unrecoverable.** From that state: `add()` divides by `liquidity` (zero); `withdraw()` computes a zero liquidity delta and calls the
PoolManager with it, which reverts with `CannotUpdateEmptyPosition`; `harvest()` and `recenter()` refuse to run with zero liquidity. There is
no owner and no other function. Every path was simulated; all revert. The 1.111 ETH (the developer's own principal) is permanently locked.
No holder funds were involved; nobody else had deposited.

**Cost.** 1.111 ETH of principal, plus the fees v2 would have captured during the biggest volume window of the launch (roughly 1.2 ETH went to
v1 instead in the following hours).

**Fix (FeeFeeder3, `src/FeeFeeder3.sol`).**
- Principal is defined as position + idle balances; shares are valued in ETH terms. No state exists where shares own nothing.
- `recenter()` slides a window across the price and keeps the placement that converts the most of what it holds into liquidity: symmetric when
  both tokens are present, one-sided next to the price when only one is left. It reverts if it would end with zero liquidity.
- `withdraw()` pays the share of idle balances even when liquidity is zero and never makes a zero-delta position call.
- `test/FeeFeeder3.t.sol` replays the exact failure on a fork of the live pool (seed → 2x pump → recenter → withdraw), plus a dump, a
  second depositor joining while one-sided, and the normal fee path. All pass at ±10% and ±49%.

**Lesson.** The one-sided range exit is the *normal* outcome for a concentrated position on a volatile coin. It should have been the first
test, before any real deposit.
