#!/usr/bin/env python3
"""
Backing v2 keeper (runs inside perp_keeper.py when deployment_real.json has "lighterBacking").
Every V2_SECS:
  1. FeeFeeder.harvest() (LP fees → ETH to LighterBacking, PUNZ burned) every V2_HARVEST_SECS; recenter() if out of range + cooldown.
  2. LighterBacking.fund() if it holds ≥ 0.002 ETH  (ETH → USDG → the contract's Lighter account).
  3. Read the contract's Lighter account via api.rh.lighter.xyz. If short size < targetBaseTicks(), sell the difference on PONS-PERP
     with the registered trading key (market order, price floor = oracle − 3%). Minimum order 20 PONS.
  4. LighterBacking.sync(baseTicks, entryNotional) so the on-chain NAV estimate matches L2 (clamped on-chain; can only under-state).
  5. LighterBacking.settle() when USDG is sitting on the contract and claims are queued.
The trading key can only trade: Lighter pays withdrawals to the contract, and L2 transfers need the (non-existent) L1 key.
"""
import json, os, time, datetime, asyncio, urllib.request
from web3 import Web3
HOME = os.path.expanduser("~")
API = os.environ.get("LIGHTER_API", "https://api.rh.lighter.xyz")
def now(): return datetime.datetime.now().strftime("%H:%M:%S")

class LighterKeeper:
    def __init__(self, w3, send, dep, log=print):
        self.w3, self.send, self.log, self.dep = w3, send, log, dep
        o = os.path.join(HOME, "pons-perp", "out")
        self.lb = w3.eth.contract(address=Web3.to_checksum_address(dep["lighterBacking"]), abi=json.load(open(os.path.join(o, "LighterBacking.sol", "LighterBacking.json")))["abi"])
        self.ff = w3.eth.contract(address=Web3.to_checksum_address(dep["feeFeeder"]), abi=json.load(open(os.path.join(o, "FeeFeeder.sol", "FeeFeeder.json")))["abi"]) if dep.get("feeFeeder") else None
        self.market = int(dep["lighter"]["ponsMarket"]); self.sd = int(dep["lighter"]["sizeDecimals"]); self.pd = int(dep["lighter"]["priceDecimals"])
        self.key_priv = os.environ.get("LIGHTER_API_PRIV"); self.key_slot = int(os.environ.get("LIGHTER_API_KEY_INDEX", "4"))
        self.last_harvest = 0; self.last_sync = (None, None)

    def _account(self):
        idx = self.lb.functions.accountIndex().call()
        if not idx: return None, None
        a = json.load(urllib.request.urlopen(f"{API}/api/v1/account?by=index&value={idx}", timeout=15))["accounts"][0]
        pos = next((p for p in a.get("positions", []) if int(p.get("market_id", -1)) == self.market and float(p.get("position") or 0) != 0), None)
        return idx, (a, pos)

    def _sell(self, idx, ticks, floor_ticks):
        from lighter.signer_client import SignerClient
        async def go():
            c = SignerClient(url=API, account_index=idx, api_private_keys={self.key_slot: self.key_priv}, chain_id=466324)
            tx, resp, err = await c.create_market_order(market_index=self.market, client_order_index=int(time.time()) % 1_000_000, base_amount=int(ticks),
                                                        avg_execution_price=int(floor_ticks), is_ask=True, api_key_index=self.key_slot)
            await c.close(); return (getattr(resp, "code", None), err)
        return asyncio.run(go())

    def step(self):
        acted = []
        # 1. LP fees → v2
        if self.ff and time.time() - self.last_harvest > float(os.environ.get("V2_HARVEST_SECS", "300")):
            self.last_harvest = time.time()
            try:
                if self.ff.functions.liquidity().call() > 0:
                    if not self.ff.functions.inRange().call() and time.time() > self.ff.functions.lastRecenter().call() + 1800:
                        h, st = self.send(self.ff.functions.recenter()); acted.append(f"recenter {'OK' if st == 1 else 'REV'} {h[:10]}")
                    h, st = self.send(self.ff.functions.harvest()); acted.append(f"harvest {'OK' if st == 1 else 'REV'} {h[:10]}")
            except Exception as ex: acted.append(f"harvest skip: {str(ex)[:60]}")
        # 2. ETH → USDG → Lighter
        try:
            if self.w3.eth.get_balance(self.lb.address) >= Web3.to_wei(0.002, "ether"):
                h, st = self.send(self.lb.functions.fund()); acted.append(f"fund {'OK' if st == 1 else 'REV'} {h[:10]}")
        except Exception as ex: acted.append(f"fund skip: {str(ex)[:60]}")
        # 3. size the short to target
        try:
            idx, st = self._account()
            if idx and st:
                a, pos = st
                cur_ticks = int(round(abs(float(pos["position"])) * 10 ** self.sd)) if pos else 0
                is_short = bool(pos) and str(pos.get("sign")) in ("-1", "-")
                target = self.lb.functions.targetBaseTicks().call()
                px = self.lb.functions.ponsPriceTicks().call()
                if self.key_priv and self.lb.functions.keyRegistered().call():
                    need = target - (cur_ticks if is_short else 0)
                    if need >= 20 * 10 ** self.sd and float(a.get("available_balance") or 0) > 1:
                        code, err = self._sell(idx, need, px * 97 // 100)
                        acted.append(f"SELL {need / 10 ** self.sd:.1f} PONS (target {target / 10 ** self.sd:.1f}) -> {code} {err or ''}")
                # 4. mirror on-chain
                entry = int(round(cur_ticks / 10 ** self.sd * float(pos["avg_entry_price"]) * 1e6)) if (pos and is_short) else 0
                if (cur_ticks if is_short else 0, entry) != self.last_sync:
                    h, s = self.send(self.lb.functions.sync(cur_ticks if is_short else 0, entry)); self.last_sync = (cur_ticks if is_short else 0, entry)
                    acted.append(f"sync short {cur_ticks / 10 ** self.sd:.1f} PONS @ {pos['avg_entry_price'] if pos else '-'} {'OK' if s == 1 else 'REV'} {h[:10]}")
        except Exception as ex: acted.append(f"trade/sync skip: {str(ex)[:80]}")
        # 5. pay claims
        try:
            USDG = self.w3.eth.contract(address="0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", abi=json.loads('[{"name":"balanceOf","type":"function","inputs":[{"type":"address"}],"outputs":[{"type":"uint256"}],"stateMutability":"view"}]'))
            bal = USDG.functions.balanceOf(self.lb.address).call()
            if bal > 0 and (self.lb.functions.nextClaim().call() < self.lb.functions.claimCount().call() or bal >= 1_000_000):
                h, s = self.send(self.lb.functions.settle()); acted.append(f"settle {bal / 1e6:.4f} USDG {'OK' if s == 1 else 'REV'} {h[:10]}")
        except Exception as ex: acted.append(f"settle skip: {str(ex)[:60]}")
        if acted: self.log(f"[{now()}] v2 | " + " · ".join(acted))
        return acted
