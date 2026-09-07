#!/usr/bin/env python3
"""
PonsPerp live tracker — proves the short works, in real time.

Every POLL seconds reads from Robinhood Chain:
  PONS price (WETH per PONS, 5-min TWAP the perp pool uses) | sPONS NAV | lPONS NAV |
  TSPONS price in sPONS | TSPONS implied ETH price (via sPONS) | TSPONS ETH-pool price | gap between the two
Logs a line each poll and Telegram-pings whenever PONS has moved more than ALERT_BPS since the last ping,
showing exactly how sPONS and the coin repriced. Reads .env for RPC + Telegram; addresses from ~/pons-perp/deployment.json.

    cd ~/backpack-watcher && caffeinate -i python3 -u perp_tracker.py
"""
import json, os, time, datetime, urllib.request
from web3 import Web3

HOME = os.path.expanduser("~")
def _load_env(p):
    try:
        for ln in open(p):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError:
        pass
_load_env(os.path.join(HOME, "backpack-watcher", ".env")); _load_env(os.path.join(HOME, "pons-sniper", ".env"))

POLL = float(os.environ.get("PERP_TRACK_POLL", "60"))
ALERT_BPS = float(os.environ.get("PERP_TRACK_ALERT_BPS", "200"))  # ping on 2% PONS moves
DEP = json.load(open(os.environ.get("PERP_DEPLOYMENT", os.path.join(HOME, "pons-perp", "deployment.json"))))
w3 = Web3(Web3.HTTPProvider(os.environ["RH_RPC_URL"], request_kwargs={"timeout": 30, "headers": {"User-Agent": "Mozilla/5.0"}}))
PM = Web3.to_checksum_address("0x8366a39cc670b4001a1121b8f6a443a643e40951")
PERP = w3.eth.contract(address=Web3.to_checksum_address(DEP["pool"]),
                       abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "PonsPerpPool.sol", "PonsPerpPool.json")))["abi"])
pm = w3.eth.contract(address=PM, abi=json.loads('[{"name":"extsload","type":"function","inputs":[{"type":"bytes32"}],"outputs":[{"type":"bytes32"}],"stateMutability":"view"}]'))
SPONS = DEP["shortToken_sPONS"]; TSPONS = DEP["v4_test_launch"]["coin_TSPONS"]
def pool_id(c0, c1, fee, ts):
    from eth_abi import encode
    return Web3.keccak(encode(["address", "address", "uint24", "int24", "address"], [c0, c1, fee, ts, "0x" + "0" * 40]))
ID_TS_SPONS = pool_id(Web3.to_checksum_address(TSPONS), Web3.to_checksum_address(SPONS), 10000, 200)
ID_TS_ETH = pool_id("0x" + "0" * 40, Web3.to_checksum_address(TSPONS), 10000, 200)
def v4_price(pid):  # currency1 per currency0, float
    slot = Web3.keccak(pid + (6).to_bytes(32, "big"))
    s0 = int.from_bytes(pm.functions.extsload(slot).call(), "big") & ((1 << 160) - 1)
    return (s0 / 2 ** 96) ** 2

def now(): return datetime.datetime.now().strftime("%m-%d %H:%M:%S")
def telegram(msg):
    tok, chat = os.environ.get("TG_BOT_TOKEN"), os.environ.get("TG_CHAT_ID")
    if not (tok and chat): return
    try:
        body = json.dumps({"chat_id": chat, "text": msg}).encode()
        urllib.request.urlopen(urllib.request.Request(f"https://api.telegram.org/bot{tok}/sendMessage", data=body,
                               headers={"Content-Type": "application/json"}), timeout=10)
    except Exception as e:
        print(f"[{now()}] telegram fail: {e}")

BACKING = None
if DEP.get("backing"):
    BACKING = w3.eth.contract(address=Web3.to_checksum_address(DEP["backing"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "Backing.sol", "Backing.json")))["abi"])
    ID_COIN_ETH = pool_id("0x" + "0" * 40, Web3.to_checksum_address(TSPONS), int(DEP.get("poolKey", {}).get("fee", 30000)), 200)

def snapshot():
    pons = PERP.functions.twapPriceX96().call() / 2 ** 96          # ETH per PONS
    nav_s = PERP.functions.sharePriceWei(1).call() / 1e18             # ETH per sPONS
    nav_l = PERP.functions.sharePriceWei(0).call() / 1e18
    if BACKING:  # POONS/PUNZ design: coin trades vs ETH; "implied" = floor (backing per coin)
        p = v4_price(ID_COIN_ETH)
        ethpool = (1 / p) if p else 0.0
        implied = BACKING.functions.floorWeiPerToken().call() / 1e18
        return dict(pons=pons, nav_s=nav_s, nav_l=nav_l, spons_per_ts=0.0, implied=implied, ethpool=ethpool)
    spons_per_ts = v4_price(ID_TS_SPONS)                             # currency0=TSPONS, currency1=sPONS
    implied = spons_per_ts * nav_s                                    # ETH per TSPONS via the short
    p = v4_price(ID_TS_ETH); ethpool = (1 / p) if p else 0.0
    return dict(pons=pons, nav_s=nav_s, nav_l=nav_l, spons_per_ts=spons_per_ts, implied=implied, ethpool=ethpool)

def fmt(s):
    gap = ((s["ethpool"] / s["implied"] - 1) * 100) if s["implied"] else float("nan")
    return (f"PONS {s['pons']:.8f} ETH | sPONS NAV {s['nav_s']:.8f} | lPONS {s['nav_l']:.8f} | "
            f"TSPONS {s['spons_per_ts']:.3e} sPONS = {s['implied']:.3e} ETH implied | ETH-pool {s['ethpool']:.3e} ETH | chart gap {gap:+.1f}%")

def main():
    base = snapshot(); last_ping = base
    print(f"[{now()}] tracker start | {fmt(base)}", flush=True)
    telegram(f"📈 sPONS tracker armed\n{fmt(base)}")
    while True:
        time.sleep(POLL)
        try:
            s = snapshot()
        except Exception as e:
            print(f"[{now()}] rpc fail: {str(e)[:80]}", flush=True); continue
        print(f"[{now()}] {fmt(s)}", flush=True)
        move = (s["pons"] / last_ping["pons"] - 1) * 10000
        if abs(move) >= ALERT_BPS:
            d_s = (s["nav_s"] / last_ping["nav_s"] - 1) * 100; d_l = (s["nav_l"] / last_ping["nav_l"] - 1) * 100
            d_c = (s["implied"] / last_ping["implied"] - 1) * 100
            msg = (f"{'🔻' if move < 0 else '🔺'} PONS {move/100:+.2f}% vs ETH since last ping\n"
                   f"→ sPONS NAV {d_s:+.2f}%  |  lPONS NAV {d_l:+.2f}%\n"
                   f"→ TSPONS implied ETH value {d_c:+.2f}%  (ETH-pool chart gap {(s['ethpool']/s['implied']-1)*100:+.1f}% — arb opportunity)\n"
                   f"since tracker start: PONS {(s['pons']/base['pons']-1)*100:+.2f}%, sPONS {(s['nav_s']/base['nav_s']-1)*100:+.2f}%")
            print(f"[{now()}] PING: " + msg.replace("\n", " | "), flush=True)
            telegram(msg); last_ping = s

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: print("\nbye")
