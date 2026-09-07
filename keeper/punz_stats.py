#!/usr/bin/env python3
"""
PUNZ protocol stats — hourly buckets built from chain events since launch, persisted to punz_stats.json.
Used by perp_dash.py for /stats.json and /stats. Everything here is derived from logs: swaps on the PUNZ/ETH pool (volume, implied
fees), PUNZ Transfer-to-zero (burns), Backing Harvested (ETH delivered into the v1 short) and Payout (redemptions).
"""
import json, os, time, threading
from web3 import Web3

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, "backpack-watcher", "punz_stats.json")
FEE = 0.03

class Stats:
    def __init__(self, w3, parse, addrs, launch_ts, lock):
        self.w3, self.parse, self.addrs, self.launch_ts, self.lock = w3, parse, addrs, launch_ts, lock
        self.buckets = {}      # hour (unix, floored) -> dict
        self.scanned_to = 0    # last block fully covered by the backfill
        self.seen = set()
        self.ready = False
        try:
            d = json.load(open(STATE)); self.buckets = {int(k): v for k, v in d["buckets"].items()}; self.scanned_to = d["scanned_to"]
        except Exception: pass

    def _b(self, t):
        h = int(t) // 3600 * 3600
        return self.buckets.setdefault(h, {"buy_eth": 0.0, "sell_eth": 0.0, "buys": 0, "sells": 0, "buy_coin": 0.0, "sell_coin": 0.0,
                                           "burned": 0.0, "harvest_eth": 0.0, "harvest_burn": 0.0, "redeems": 0, "redeem_coin": 0.0, "redeem_spons": 0.0})

    def add(self, e):
        """e = parsed event dict with 't' (unix)."""
        b = self._b(e["t"]); k = e["kind"]
        if k == "buy": b["buy_eth"] += e["eth"]; b["buys"] += 1; b["buy_coin"] += e["coin"]
        elif k == "sell": b["sell_eth"] += e["eth"]; b["sells"] += 1; b["sell_coin"] += e["coin"]
        elif k == "burn": b["burned"] += e["coin"]
        elif k == "harvest": b["harvest_eth"] += e.get("eth_instant", 0) + e.get("eth_vault", 0); b["harvest_burn"] += e.get("burned", 0)
        elif k == "redeem": b["redeems"] += 1; b["redeem_coin"] += e["coin"]; b["redeem_spons"] += e["spons"]

    def save(self):
        tmp = STATE + ".tmp"
        json.dump({"buckets": self.buckets, "scanned_to": self.scanned_to}, open(tmp, "w")); os.replace(tmp, STATE)

    def _block_at(self, ts):
        lo, hi = 1, self.w3.eth.block_number
        while lo < hi:
            mid = (lo + hi) // 2
            if self.w3.eth.get_block(mid)["timestamp"] < ts: lo = mid + 1
            else: hi = mid
        return lo

    def backfill(self, upto_block, ts_of_block, log=print):
        """Scan [launch, upto_block] once (resumable). Runs in a thread; the live poller covers blocks after upto_block."""
        try:
            start = self.scanned_to + 1 if self.scanned_to else self._block_at(self.launch_ts) - 50
            if start <= upto_block:
                log(f"stats backfill {start}..{upto_block} ({upto_block - start + 1} blocks)")
                frm = start
                while frm <= upto_block:
                    to = min(frm + 4999, upto_block)
                    for attempt in range(4):
                        try:
                            logs = self.w3.eth.get_logs({"fromBlock": frm, "toBlock": to, "address": self.addrs}); break
                        except Exception as ex:
                            if attempt == 3: raise
                            time.sleep(2)
                    if logs:   # interpolate timestamps across the chunk (hour buckets; avoids one RPC per event)
                        t_a = self.w3.eth.get_block(frm)["timestamp"]; t_b = self.w3.eth.get_block(to)["timestamp"]
                        span = max(1, to - frm)
                    for lg in logs:
                        p = self.parse(lg)
                        if p and p["kind"] in ("buy", "sell", "burn", "harvest", "redeem"):
                            p["t"] = t_a + (lg["blockNumber"] - frm) * (t_b - t_a) / span
                            with self.lock: self.add(p)
                    self.scanned_to = to; frm = to + 1
                    if (to // 5000) % 10 == 0: self.save()
                self.save(); log(f"stats backfill done → {len(self.buckets)} hourly buckets")
            self.ready = True
        except Exception as ex:
            log(f"stats backfill error: {str(ex)[:120]}")

    def summary(self, snap, now=None):
        """Aggregate for /stats.json. snap = latest dashboard snapshot (for live exposure)."""
        now = now or time.time()
        with self.lock: B = sorted(self.buckets.items())
        tot = {k: 0.0 for k in ("buy_eth", "sell_eth", "buys", "sells", "buy_coin", "sell_coin", "burned", "harvest_eth", "harvest_burn", "redeems", "redeem_coin", "redeem_spons")}
        for _, b in B:
            for k in tot: tot[k] += b.get(k, 0)
        def series(step):
            out = {}
            for h, b in B:
                key = h // step * step
                o = out.setdefault(key, {"t": key, "volume_eth": 0.0, "buy_eth": 0.0, "sell_eth": 0.0, "trades": 0, "fees_eth_to_short": 0.0, "fees_coin_burned": 0.0, "burned": 0.0, "delivered_eth": 0.0, "redeems": 0})
                o["volume_eth"] += b["buy_eth"] + b["sell_eth"]; o["buy_eth"] += b["buy_eth"]; o["sell_eth"] += b["sell_eth"]; o["trades"] += b["buys"] + b["sells"]
                o["fees_eth_to_short"] += b["buy_eth"] * FEE; o["fees_coin_burned"] += b["sell_coin"] * FEE
                o["burned"] += b["burned"]; o["delivered_eth"] += b["harvest_eth"]; o["redeems"] += b["redeems"]
            return [out[k] for k in sorted(out)]
        eth_usd = snap.get("eth_usd") or 0
        v1_value_eth = (snap.get("backing_spons") or 0) * (snap.get("nav_s") or 0)
        v2_col = snap.get("lighter_collateral") or snap.get("v2_collateral_usdg") or 0
        v2_pos = abs(snap.get("lighter_position_pons") or snap.get("v2_short_pons") or 0)
        v2_entry = snap.get("lighter_entry") or 0; v2_upnl = snap.get("lighter_upnl") or 0
        mark = (v2_entry + (v2_upnl / v2_pos if v2_pos else 0)) if v2_entry else 0
        return {
            "generated_at": int(now), "since": int(self.launch_ts), "backfill_complete": self.ready,
            "split": {"holders_pct": 100, "creator_pct": 0, "treasury_pct": 0, "keeper_pct": 0,
                      "note": "every fee is either ETH into the PONS short or PUNZ burned; no address takes a cut"},
            "volume": {"eth": tot["buy_eth"] + tot["sell_eth"], "usd": (tot["buy_eth"] + tot["sell_eth"]) * eth_usd, "buys": int(tot["buys"]), "sells": int(tot["sells"]),
                       "buy_eth": tot["buy_eth"], "sell_eth": tot["sell_eth"]},
            "fees": {"generated_eth": tot["buy_eth"] * FEE, "generated_coin": tot["sell_coin"] * FEE,
                     "delivered_to_v1_short_eth": snap.get("eth_to_short") or tot["harvest_eth"],
                     "delivered_to_v2_short_eth": snap.get("ff_eth_fed") or 0,
                     "coin_burned": snap.get("burned") or tot["burned"], "burned_pct_of_supply": ((snap.get("burned") or tot["burned"]) / 1e9) * 100},
            "backing": {"v1_spons": snap.get("backing_spons"), "v1_value_eth": v1_value_eth, "v1_value_usd": v1_value_eth * eth_usd,
                        "v1_floor_eth_per_coin": snap.get("floor"), "v2_collateral_usdg": v2_col, "v2_short_pons": v2_pos, "v2_entry": v2_entry, "v2_mark": mark,
                        "v2_notional_usd": v2_pos * mark, "v2_upnl_usdg": v2_upnl, "v2_liq": snap.get("lighter_liq"),
                        "total_backing_usd": v1_value_eth * eth_usd + v2_col + v2_upnl,
                        "supply": snap.get("supply"), "market_cap_usd": (snap.get("ethpool") or 0) * eth_usd * (snap.get("supply") or 0)},
            "redemptions": {"count": int(tot["redeems"]), "coin": tot["redeem_coin"], "spons_paid": tot["redeem_spons"]},
            "daily": series(86400), "hourly": series(3600)[-72:],
        }
