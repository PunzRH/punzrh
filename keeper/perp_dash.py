#!/usr/bin/env python3
"""
sPONS live dashboard — http://localhost:8765

Polls Robinhood Chain every POLL seconds (same reads as perp_tracker.py), keeps a history (seeded from
perp_tracker.out and persisted to perp_dash_history.json), and serves a single page charting:
  PONS price vs ETH  |  sPONS NAV  |  lPONS NAV  |  TSPONS implied ETH value  (all normalized to 100 at start)
plus the raw live numbers. Screen-record it: this is the tokenized PONS short moving inversely to PONS, live.

    cd ~/backpack-watcher && caffeinate -i python3 -u perp_dash.py
"""
import json, os, re, time, threading, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from web3 import Web3
from eth_abi import encode

HOME = os.path.expanduser("~")
HERE = os.path.join(HOME, "backpack-watcher")
def _load_env(p):
    try:
        for ln in open(p):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError:
        pass
_load_env(os.path.join(HERE, ".env")); _load_env(os.path.join(HOME, "pons-sniper", ".env"))

PORT = int(os.environ.get("PERP_DASH_PORT", "8765"))
POLL = float(os.environ.get("PERP_DASH_POLL", "30"))
DEP_PATH = os.environ.get("PERP_DEPLOYMENT", os.path.join(HOME, "pons-perp", "deployment.json"))
HIST = os.path.join(HERE, "perp_dash_history" + ("" if DEP_PATH.endswith("deployment.json") else "_" + os.path.basename(DEP_PATH).split(".")[0]) + ".json")
DEP = json.load(open(DEP_PATH))
w3 = Web3(Web3.HTTPProvider(os.environ["RH_RPC_URL"], request_kwargs={"timeout": 30, "headers": {"User-Agent": "Mozilla/5.0"}}))
PERP = w3.eth.contract(address=Web3.to_checksum_address(DEP["pool"]),
                       abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "PonsPerpPool.sol", "PonsPerpPool.json")))["abi"])
PM = w3.eth.contract(address=Web3.to_checksum_address("0x8366a39cc670b4001a1121b8f6a443a643e40951"),
                     abi=json.loads('[{"name":"extsload","type":"function","inputs":[{"type":"bytes32"}],"outputs":[{"type":"bytes32"}],"stateMutability":"view"}]'))
SPONS = Web3.to_checksum_address(DEP["shortToken_sPONS"]); TSPONS = Web3.to_checksum_address(DEP["v4_test_launch"]["coin_TSPONS"])
ZERO = "0x" + "0" * 40
def pool_id(c0, c1, fee, ts): return Web3.keccak(encode(["address", "address", "uint24", "int24", "address"], [c0, c1, fee, ts, ZERO]))
ID_TS_SPONS = pool_id(TSPONS, SPONS, 10000, 200); ID_TS_ETH = pool_id(ZERO, TSPONS, 10000, 200)
def v4_price(pid):
    s0 = int.from_bytes(PM.functions.extsload(Web3.keccak(pid + (6).to_bytes(32, "big"))).call(), "big") & ((1 << 160) - 1)
    return (s0 / 2 ** 96) ** 2

BACKING = None
if DEP.get("backing"):
    BACKING = w3.eth.contract(address=Web3.to_checksum_address(DEP["backing"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "Backing.sol", "Backing.json")))["abi"])
    ID_COIN_ETH = pool_id(ZERO, TSPONS, int(DEP.get("poolKey", {}).get("fee", 30000)), 200)

def snapshot():
    pons = PERP.functions.twapPriceX96().call() / 2 ** 96
    nav_s = PERP.functions.sharePriceWei(1).call() / 1e18
    nav_l = PERP.functions.sharePriceWei(0).call() / 1e18
    s = {"t": int(time.time()), "pons": pons, "nav_s": nav_s, "nav_l": nav_l,
         "long_bal": PERP.functions.longBal().call() / 1e18, "short_bal": PERP.functions.shortBal().call() / 1e18,
         "epochs": PERP.functions.epochCount().call()}
    if BACKING:
        s["ethpool"] = 1 / v4_price(ID_COIN_ETH)                       # coin market price in ETH
        s["floor"] = BACKING.functions.floorWeiPerToken().call() / 1e18  # backing per coin in ETH
        s["backing_spons"] = BACKING.functions.sponsBacking().call() / 1e18
        s["eth_to_short"] = (BACKING.functions.totalEthCommitted().call() + BACKING.functions.totalEthSwapped().call()) / 1e18  # vault path + instant market path
        s["burned"] = BACKING.functions.totalCoinBurned().call() / 1e18
        s["implied"] = s["floor"]; s["spons_per_ts"] = 0
        # ---- Backing v2 (Lighter short) + FeeFeeder, if deployed
        if DEP.get("lighterBacking"):
            try:
                if "LB" not in globals():
                    globals()["LB"] = w3.eth.contract(address=Web3.to_checksum_address(DEP["lighterBacking"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "LighterBacking.sol", "LighterBacking.json")))["abi"])
                    globals()["FF"] = w3.eth.contract(address=Web3.to_checksum_address(DEP["feeFeeder"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "FeeFeeder.sol", "FeeFeeder.json")))["abi"]) if DEP.get("feeFeeder") else None
                s["v2_collateral_usdg"] = LB.functions.collateralUnits().call() / 1e6
                s["v2_short_pons"] = LB.functions.baseTicks().call() / 10 ** DEP["lighter"]["sizeDecimals"]
                s["v2_equity_usdg"] = LB.functions.equityUnits().call() / 1e6
                s["v2_floor_usdg_per_punz"] = LB.functions.floorUnitsPerPunz().call() / 1e6
                s["v2_eth_waiting"] = w3.eth.get_balance(LB.address) / 1e18
                if FF: s["ff_liquidity"] = FF.functions.liquidity().call(); s["ff_eth_fed"] = FF.functions.totalEthFed().call() / 1e18; s["ff_punz_burned"] = FF.functions.totalPunzBurned().call() / 1e18; s["ff_in_range"] = FF.functions.inRange().call()
                # live view of the position from the Robinhood Lighter API (display only; the contract never depends on it)
                import urllib.request as _u
                acct = LB.functions.accountIndex().call()
                if acct:
                    a = json.load(_u.urlopen(f"https://api.rh.lighter.xyz/api/v1/account?by=index&value={acct}", timeout=15))["accounts"][0]
                    s["lighter_account"] = acct; s["lighter_collateral"] = float(a.get("collateral") or 0)
                    for p in a.get("positions", []):
                        if p.get("market_id") == DEP["lighter"]["ponsMarket"]:
                            s["lighter_position_pons"] = float(p.get("position") or 0) * (-1 if str(p.get("sign")) in ("-1", "-") else 1)
                            s["lighter_entry"] = float(p.get("avg_entry_price") or 0); s["lighter_upnl"] = float(p.get("unrealized_pnl") or 0); s["lighter_liq"] = float(p.get("liquidation_price") or 0)
            except Exception as e:
                print("v2 snapshot fail:", str(e)[:80], flush=True)
    else:
        spt = v4_price(ID_TS_SPONS)
        s.update({"spons_per_ts": spt, "implied": spt * nav_s, "ethpool": 1 / v4_price(ID_TS_ETH)})
    return s

history = []
lock = threading.Lock()

def seed_from_tracker():
    p = os.path.join(HERE, "perp_tracker.out")
    if not os.path.exists(p): return
    rx = re.compile(r"\[(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\].*?PONS ([0-9.]+) ETH \| sPONS NAV ([0-9.]+) \| lPONS ([0-9.]+) \| TSPONS ([0-9.e+-]+) sPONS = ([0-9.e+-]+) ETH implied \| ETH-pool ([0-9.e+-]+)")
    yr = datetime.datetime.now().year
    for ln in open(p):
        m = rx.search(ln)
        if not m: continue
        mo, d, H, M, S = map(int, m.groups()[:5])
        t = int(datetime.datetime(yr, mo, d, H, M, S).timestamp())
        history.append({"t": t, "pons": float(m.group(6)), "nav_s": float(m.group(7)), "nav_l": float(m.group(8)),
                        "spons_per_ts": float(m.group(9)), "implied": float(m.group(10)), "ethpool": float(m.group(11))})

def poller():
    while True:
        try:
            s = snapshot()
            with lock:
                history.append(s)
                json.dump(history[-20000:], open(HIST, "w"))
        except Exception as e:
            print("poll fail:", str(e)[:80], flush=True)
        time.sleep(POLL)

# ---- live event feed (for /live): swaps on the coin pool + sPONS pool, harvests, vault rebalances/commits, burns, redeems
events = []          # newest last: {t, block, tx, kind, msg, ...}
_ev_seen = set()
_blk_ts = {}
def _ts(bn):
    if bn not in _blk_ts: _blk_ts[bn] = w3.eth.get_block(bn).timestamp
    return _blk_ts[bn]
def _sig(s): return Web3.keccak(text=s).hex() if Web3.keccak(text=s).hex().startswith("0x") else "0x" + Web3.keccak(text=s).hex()
T_SWAP = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"  # v4 PoolManager Swap (observed on-chain; PoolId is a user type so keccak(text) differs)
T_TRANSFER = _sig("Transfer(address,address,uint256)")
T_HARVEST = _sig("Harvested(uint256,uint256,uint256,uint256)"); T_BCLAIM = _sig("Claimed(uint256,uint256)"); T_PAYOUT = _sig("Payout(address,uint256,uint256)")
T_REBAL = _sig("Rebalanced(uint256,uint256,uint256,uint256)"); T_COMMIT = _sig("Committed(uint256,address,uint8,bool,uint256)")
COIN_ADDR = TSPONS; BACK_ADDR = Web3.to_checksum_address(DEP["backing"]) if DEP.get("backing") else None; VAULT_ADDR = Web3.to_checksum_address(DEP["pool"])
PM_ADDR = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
PID_COIN = "0x" + ID_COIN_ETH.hex().replace("0x", "") if BACKING else None
PID_SPONS = "0x" + pool_id(ZERO, SPONS, 3000, 60).hex().replace("0x", "")
_SYMBOL = DEP.get("symbol", "COIN")
def _dec(data, types):
    # all our event fields are single static words; decode by hand (eth_abi strict mode rejects sign-extended int128/int24 padding)
    raw = bytes.fromhex(data.hex().replace("0x", "")) if hasattr(data, "hex") else bytes.fromhex(str(data).replace("0x", ""))
    out = []
    for i, ty in enumerate(types):
        w = raw[i * 32:(i + 1) * 32]
        if ty == "bool": out.append(int.from_bytes(w, "big") != 0)
        elif ty.startswith("int"): out.append(int.from_bytes(w, "big", signed=True))
        else: out.append(int.from_bytes(w, "big"))
    return out
def _addr(topic): return Web3.to_checksum_address("0x" + (topic.hex() if hasattr(topic, "hex") else str(topic)).replace("0x", "")[-40:])
def _parse(lg):
    t0 = lg["topics"][0].hex() if hasattr(lg["topics"][0], "hex") else str(lg["topics"][0]); t0 = t0 if t0.startswith("0x") else "0x" + t0
    a = lg["address"]; out = None
    if a.lower() == PM_ADDR.lower() and t0 == T_SWAP:
        pid = lg["topics"][1].hex() if hasattr(lg["topics"][1], "hex") else str(lg["topics"][1]); pid = pid if pid.startswith("0x") else "0x" + pid
        a0, a1, sq, liq, fee, tick = _dec(lg["data"], ["int128", "int128", "uint160", "uint128", "uint24", "int24"])
        if PID_COIN and pid.lower() == PID_COIN.lower():
            if a0 < 0: out = {"kind": "buy", "eth": -a0 / 1e18, "coin": a1 / 1e18, "msg": f"BUY {a1/1e18:,.0f} {_SYMBOL} for {-a0/1e18:.4f} ETH → 3% fee to the short"}
            else: out = {"kind": "sell", "eth": a0 / 1e18, "coin": -a1 / 1e18, "msg": f"SELL {-a1/1e18:,.0f} {_SYMBOL} for {a0/1e18:.4f} ETH → 3% fee burned"}
        elif pid.lower() == PID_SPONS.lower():
            if a0 < 0: out = {"kind": "spons_buy", "eth": -a0 / 1e18, "spons": a1 / 1e18, "msg": f"sPONS market: bought {a1/1e18:.2f} sPONS for {-a0/1e18:.4f} ETH"}
            else: out = {"kind": "spons_sell", "eth": a0 / 1e18, "spons": -a1 / 1e18, "msg": f"sPONS market: sold {-a1/1e18:.2f} sPONS for {a0/1e18:.4f} ETH (peg → NAV)"}
    elif BACK_ADDR and a.lower() == BACK_ADDR.lower():
        if t0 == T_HARVEST:
            ei, sb, ec, cb = _dec(lg["data"], ["uint256"] * 4)
            parts = []
            if sb: parts.append(f"{ei/1e18:.4f} ETH → {sb/1e18:.2f} sPONS on market")
            if ec: parts.append(f"{ec/1e18:.4f} ETH → vault mint (sPONS in 2 min)")
            if cb: parts.append(f"🔥 burned {cb/1e18:,.0f} {_SYMBOL}")
            out = {"kind": "harvest", "eth_instant": ei / 1e18, "spons": sb / 1e18, "eth_vault": ec / 1e18, "burned": cb / 1e18, "msg": "HARVEST: " + (" · ".join(parts) or "nothing to collect")}
        elif t0 == T_BCLAIM:
            i, so = _dec(lg["data"], ["uint256", "uint256"]); out = {"kind": "backing_claim", "spons": so / 1e18, "msg": f"vault minted {so/1e18:.2f} sPONS into Backing (at NAV)"}
        elif t0 == T_PAYOUT:
            b, so = _dec(lg["data"], ["uint256", "uint256"]); out = {"kind": "redeem", "coin": b / 1e18, "spons": so / 1e18, "msg": f"REDEEM: {b/1e18:,.0f} {_SYMBOL} burned → {so/1e18:.3f} sPONS paid to {_addr(lg['topics'][1])[:8]}…"}
    elif a.lower() == VAULT_ADDR.lower():
        if t0 == T_REBAL:
            px, lb, sb = _dec(lg["data"], ["uint256"] * 3)
            out = {"kind": "rebalance", "pons": px / 2 ** 96, "long": lb / 1e18, "short": sb / 1e18, "msg": f"REBALANCE: PONS {px/2**96:.8f} ETH · long {lb/1e18:.3f} / short {sb/1e18:.3f} ETH"}
        elif t0 == T_COMMIT:
            side, isburn, amt = _dec(lg["data"], ["uint8", "bool", "uint256"]); who = _addr(lg["topics"][2])
            if who.lower() != (BACK_ADDR or "").lower():
                out = {"kind": "commit", "side": side, "burn": isburn, "msg": f"{'BURN' if isburn else 'MINT'} {'SHORT' if side else 'LONG'}: {amt/1e18:.4f} {'shares' if isburn else 'ETH'} by {who[:8]}…"}
    elif a.lower() == COIN_ADDR.lower() and t0 == T_TRANSFER and _addr(lg["topics"][2]) == ZERO:
        v = _dec(lg["data"], ["uint256"])[0]; out = {"kind": "burn", "coin": v / 1e18, "msg": f"🔥 {v/1e18:,.0f} {_SYMBOL} burned"}
    elif a.lower() == SPONS.lower() and t0 == T_TRANSFER and BACK_ADDR and _addr(lg["topics"][2]) == BACK_ADDR:
        v = _dec(lg["data"], ["uint256"])[0]; frm = _addr(lg["topics"][1])
        if frm not in (ZERO,) and frm.lower() != PM_ADDR.lower():
            out = {"kind": "donate", "spons": v / 1e18, "msg": f"💝 {v/1e18:.2f} sPONS sent to Backing by {frm[:8]}… (floor up for everyone)"}
    return out
def event_poller():
    last = w3.eth.block_number - int(os.environ.get("EVENT_LOOKBACK_BLOCKS", "15000"))
    addrs = [PM_ADDR, VAULT_ADDR, COIN_ADDR, SPONS] + ([BACK_ADDR] if BACK_ADDR else [])
    while True:
        try:
            head = w3.eth.block_number
            if head > last:
                frm = last + 1; new = []
                while frm <= head:
                    to = min(frm + 1999, head)
                    for lg in w3.eth.get_logs({"fromBlock": frm, "toBlock": to, "address": addrs}):
                        key = (lg["transactionHash"].hex(), lg["logIndex"])
                        if key in _ev_seen: continue
                        p = _parse(lg)
                        if p:
                            _ev_seen.add(key); th = lg["transactionHash"].hex(); th = th if th.startswith("0x") else "0x" + th
                            p.update({"t": _ts(lg["blockNumber"]), "block": lg["blockNumber"], "tx": th}); new.append(p)
                    frm = to + 1
                if new:
                    new.sort(key=lambda e: (e["block"], e["tx"]))
                    with lock:
                        events.extend(new); del events[:-400]
                last = head
        except Exception as e:
            print("event poll fail:", str(e)[:100], flush=True)
        time.sleep(12)

PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>sPONS — tokenized PONS short, live</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<style>body{margin:0;background:#0b0f14;color:#e6edf3;font:14px -apple-system,Inter,system-ui,sans-serif}
.wrap{max-width:1200px;margin:0 auto;padding:24px}h1{font-size:22px;margin:0 0 4px}.sub{color:#8b949e;margin-bottom:18px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:18px}
.tile{background:#111823;border:1px solid #1f2a37;border-radius:10px;padding:14px}.tile .k{color:#8b949e;font-size:12px}
.tile .v{font-size:22px;font-weight:600;margin-top:4px;font-variant-numeric:tabular-nums}.tile .d{font-size:12px;margin-top:2px}
.up{color:#3fb950}.down{color:#f85149}.card{background:#111823;border:1px solid #1f2a37;border-radius:10px;padding:14px;margin-bottom:14px}
.foot{color:#8b949e;font-size:12px}code{color:#c9d1d9}</style></head><body><div class="wrap">
<h1>__SYM__ — live status of the tokenized PONS short, Robinhood Chain</h1>
<div class="sub">Every minute the vault reads PONS's own Uniswap pool and moves ETH between the long and short sides. When PONS falls, sPONS gains — and the floor under every __SYM__ rises with it. 3% of every __SYM__ buy is converted into sPONS held by the Backing contract; 3% of every sell is burned. Vault owner renounced, liquidity locked, no admin keys. Data straight from chain every 30s.</div>
<div class="tiles" id="tiles"></div>
<div class="card"><canvas id="c" height="110"></canvas></div>
<div class="foot">Chart normalized to 100 at the start of the window. __SYM__ <code>__COIN__</code> · Vault <code>__VAULT__</code> · Backing <code>__BACKING__</code> · sPONS <code>__SPONS__</code> · <a href="https://rh-scan.com/address/__VAULT__" style="color:#58a6ff">verify on rh-scan</a> · <a href="https://punzrh.com" style="color:#58a6ff">punzrh.com</a> · <a href="/how" style="color:#58a6ff;font-weight:600">How it works →</a> · <a href="/vault" style="color:#3fb950;font-weight:600">Vault: go long, go short, burn, redeem __SYM__ →</a></div>
</div><script>
let chart;
function pct(a,b){return ((a/b-1)*100)}
function cls(x){return x>=0?'up':'down'}
async function tick(){
  const h=await (await fetch('/data')).json(); if(!h.length) return;
  const b=h[0], n=h[h.length-1];
  const tiles=[
    ['PONS (ETH)', n.pons.toFixed(8), pct(n.pons,b.pons)],
    ['sPONS NAV (ETH)', n.nav_s.toFixed(8), pct(n.nav_s,b.nav_s)],
    ['lPONS NAV (ETH)', n.nav_l.toFixed(8), pct(n.nav_l,b.nav_l)],
  ];
  if(n.floor!==undefined){
    tiles.push(['__SYM__ market price (ETH)', n.ethpool.toExponential(3), pct(n.ethpool,b.ethpool)]);
    tiles.push(['__SYM__ FLOOR = sPONS backing per coin (ETH)', n.floor.toExponential(3), b.floor>0?pct(n.floor,b.floor):0]);
    tiles.push(['ETH of trade fees put into the PONS short', n.eth_to_short.toFixed(5), 0]);
    tiles.push(['sPONS held by Backing (redeemable)', n.backing_spons.toFixed(3), 0]);
    tiles.push(['__SYM__ burned from sell fees', Math.round(n.burned).toLocaleString(), 0]);
  } else {
    tiles.push(['TSPONS implied (ETH)', n.implied.toExponential(3), pct(n.implied,b.implied)]);
    tiles.push(['TSPONS chart pool (ETH)', n.ethpool.toExponential(3), pct(n.ethpool,b.ethpool)]);
  }
  document.getElementById('tiles').innerHTML=tiles.map(t=>`<div class="tile"><div class="k">${t[0]}</div><div class="v">${t[1]}</div><div class="d ${cls(t[2])}">${t[2]>=0?'+':''}${t[2].toFixed(2)}% since start</div></div>`).join('');
  const labels=h.map(x=>new Date(x.t*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}));
  const norm=k=>h.map(x=>100*x[k]/b[k]);
  const ds=[['PONS price',norm('pons'),'#8b949e'],['sPONS NAV (short)',norm('nav_s'),'#3fb950'],['lPONS NAV (long)',norm('nav_l'),'#f85149'],[(n.floor!==undefined?'__SYM__ floor (backing per coin)':'TSPONS implied value'),norm('implied'),'#58a6ff']];
  if(!chart){chart=new Chart(document.getElementById('c'),{type:'line',data:{labels,datasets:ds.map((d,i)=>({label:d[0],data:d[1],borderColor:d[2],borderWidth:2,pointRadius:0,tension:.2,yAxisID:i==3?'y1':'y'}))},
    options:{animation:false,plugins:{legend:{labels:{color:'#e6edf3'}}},scales:{x:{ticks:{color:'#8b949e',maxTicksLimit:12},grid:{color:'#1f2a37'}},
      y:{title:{display:true,text:'PONS / sPONS / lPONS (start = 100)',color:'#8b949e'},ticks:{color:'#8b949e'},grid:{color:'#1f2a37'}},
      y1:{position:'right',title:{display:true,text:'floor (start = 100)',color:'#58a6ff'},ticks:{color:'#58a6ff'},grid:{drawOnChartArea:false}}}}});}
  else{chart.data.labels=labels; ds.forEach((d,i)=>chart.data.datasets[i].data=d[1]); chart.update();}
}
tick(); setInterval(tick,15000);
</script></body></html>"""
_SYM = DEP.get("symbol", "TSPONS")
PAGE = (PAGE.replace("<title>sPONS — tokenized PONS short, live</title>", f"<title>{_SYM} — live status of the PONS short</title>")
            .replace("__SYM__", _SYM).replace("__COIN__", DEP.get("coin", TSPONS)).replace("__VAULT__", DEP["pool"])
            .replace("__BACKING__", DEP.get("backing", "n/a")).replace("__SPONS__", DEP["shortToken_sPONS"]))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/data"):
            with lock: body = json.dumps(history[-2000:]).encode()
            ct = "application/json"
        elif self.path.startswith("/metrics"):
            # punzrh.com readout feed: {tokenAddress, marketPriceEth, shortNavEth, backingPerPunzEth}
            with lock: n = history[-1] if history else {}
            body = json.dumps({"tokenAddress": TSPONS, "marketPriceEth": n.get("ethpool"), "shortNavEth": n.get("nav_s"),
                               "backingPerPunzEth": n.get("floor"), "updatedAt": n.get("t"),
                               # extended live-index fields (same names as site/functions/metrics.js)
                               "ponsPriceEth": n.get("pons"), "longNavEth": n.get("nav_l"), "sponsBacking": n.get("backing_spons"),
                               "feesToShortEth": n.get("eth_to_short"), "burned": n.get("burned"),
                               "vaultOwner": "0x0000000000000000000000000000000000000000", "source": "chain via keeper host, 30s poll",
                               # Backing v2 (real PONS short on Robinhood Lighter) — present once deployed
                               **{k: n.get(k) for k in ("v2_collateral_usdg", "v2_short_pons", "v2_equity_usdg", "v2_floor_usdg_per_punz", "v2_eth_waiting",
                                                        "ff_eth_fed", "ff_punz_burned", "ff_in_range", "lighter_account", "lighter_collateral",
                                                        "lighter_position_pons", "lighter_entry", "lighter_upnl", "lighter_liq") if k in n}}).encode()
            ct = "application/json"
            self.send_response(200); self.send_header("Content-Type", ct); self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        elif self.path.startswith("/long") or self.path.startswith("/vault"):
            body = LONG_PAGE.encode(); ct = "text/html; charset=utf-8"
        elif self.path.startswith("/events"):
            with lock: body = json.dumps(events[-150:]).encode()
            ct = "application/json"
            self.send_response(200); self.send_header("Content-Type", ct); self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        elif self.path.startswith("/live"):
            body = LIVE_PAGE.encode(); ct = "text/html; charset=utf-8"
        elif self.path.startswith("/how"):
            body = HOW_PAGE.encode(); ct = "text/html; charset=utf-8"
        else:
            body = PAGE.encode(); ct = "text/html; charset=utf-8"
        self.send_response(200); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

# ---- /long : one-click "go long PONS" page (mint lPONS at the vault from any wallet; no backend, talks to the wallet directly)
LONG_PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Go long PONS — __SYM__ vault</title>
<style>body{margin:0;background:#0b0f14;color:#e6edf3;font:15px -apple-system,Inter,system-ui,sans-serif}.wrap{max-width:760px;margin:0 auto;padding:24px}
h1{font-size:22px;margin:0 0 6px}.sub{color:#8b949e;margin-bottom:16px;line-height:1.45}.card{background:#111823;border:1px solid #1f2a37;border-radius:10px;padding:16px;margin-bottom:14px}
.k{color:#8b949e;font-size:12px}.v{font-size:20px;font-weight:600;font-variant-numeric:tabular-nums}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
button{background:#238636;color:#fff;border:0;border-radius:8px;padding:12px 18px;font-size:15px;font-weight:600;cursor:pointer}button:disabled{opacity:.5;cursor:default}
button.alt{background:#1f6feb}input{background:#0b0f14;color:#e6edf3;border:1px solid #30363d;border-radius:8px;padding:10px;font-size:16px;width:140px}
.log{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:#8b949e;white-space:pre-wrap;margin-top:10px}a{color:#58a6ff}.up{color:#3fb950}.warn{color:#d29922}</style></head><body><div class="wrap">
<h1>Go long PONS — the other side of the __SYM__ vault</h1>
<div class="sub">The vault is one pool of ETH with a long side and a short side. Every minute it reads PONS's price and the losing side pays the winning side out of its own balance.
The short side is funded by __SYM__ trade fees, so it is much bigger than the long side — which means <b>the long side gets a leveraged payoff</b> (each 1% PONS move pays longs
short÷long %) while it can only ever lose 1% per 1% PONS drop. No liquidation, no funding, no counterparty: you mint lPONS with ETH, you burn it for ETH. <span class="warn">Not advice. PONS can go down.</span></div>
<div class="card"><div class="grid" id="stats"></div></div>
<div class="card"><div class="k">1 · connect a wallet on Robinhood Chain (chain id 4663)</div><div style="margin-top:8px"><button id="c">Connect wallet</button> <span id="who" class="k"></span></div></div>
<div class="card"><div class="k">2 · commit ETH to the LONG side</div><div style="margin-top:8px"><input id="amt" value="0.1"> ETH &nbsp; <button id="m" disabled>Commit long</button></div>
<div class="k" style="margin-top:8px">Your lPONS is minted at the vault's NAV at the first rebalance after a full 2-minute price window (so nobody can front-run the oracle).</div></div>
<div class="card"><div class="k">3 · claim your lPONS (about 2–3 minutes after the commit)</div><div style="margin-top:8px"><button id="cl" class="alt" disabled>Claim matured commits</button> <span id="pend" class="k"></span></div></div>
<div class="log" id="log"></div>
<div class="k" style="margin-top:14px">Vault <code>__VAULT__</code> · lPONS <code>__LPONS__</code> · <a href="https://rh-scan.com/address/__VAULT__">rh-scan</a> · <a href="/">live status</a> · To exit: commitBurn on the vault burns lPONS back to ETH at NAV (wallet UI for that coming; contract is public).</div>
</div><script>
const VAULT="__VAULT__", LPONS="__LPONS__", CHAIN="0x1237";
const RPC="https://rpc.mainnet.chain.robinhood.com";
const pad=x=>x.toString(16).padStart(64,"0"); const big=h=>BigInt(h); const eth=w=>Number(w)/1e18;
let acct=null;
const log=s=>{document.getElementById('log').textContent=`[${new Date().toLocaleTimeString()}] `+s+"\n"+document.getElementById('log').textContent};
async function rpc(method,params){const r=await fetch(RPC,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})});const j=await r.json();if(j.error)throw new Error(j.error.message);return j.result}
const call=(to,data)=>rpc('eth_call',[{to,data},'latest']);
async function stats(){
  const [L,S,navL,navS]=await Promise.all([call(VAULT,'0xf1e2dbbf'),call(VAULT,'0xa3af9574'),call(VAULT,'0x6b6dfd3c'+pad(0)),call(VAULT,'0x6b6dfd3c'+pad(1))]);
  const l=eth(big(L)),s=eth(big(S)),lev=l>0?s/l:0;
  let mine='';
  if(acct){const b=await call(LPONS,'0x70a08231'+pad(BigInt(acct)));mine=`<div><div class="k">your lPONS</div><div class="v">${eth(big(b)).toFixed(2)} <span class="k">≈ ${(eth(big(b))*eth(big(navL))).toFixed(4)} ETH</span></div></div>`}
  document.getElementById('stats').innerHTML=`<div><div class="k">long side</div><div class="v">${l.toFixed(3)} ETH</div></div><div><div class="k">short side</div><div class="v">${s.toFixed(3)} ETH</div></div>
  <div><div class="k">payoff to longs per +1% PONS</div><div class="v up">+${lev.toFixed(1)}%</div></div><div><div class="k">loss to longs per −1% PONS</div><div class="v">−1.0%</div></div>
  <div><div class="k">lPONS NAV</div><div class="v">${eth(big(navL)).toFixed(8)} ETH</div></div>${mine}`;
}
async function connect(){
  if(!window.ethereum){log('no wallet found — open this page in a browser with MetaMask/Rabby/OKX etc.');return}
  const a=await window.ethereum.request({method:'eth_requestAccounts'});acct=a[0];
  try{await window.ethereum.request({method:'wallet_switchEthereumChain',params:[{chainId:CHAIN}]})}
  catch(e){if(e.code===4902){await window.ethereum.request({method:'wallet_addEthereumChain',params:[{chainId:CHAIN,chainName:'Robinhood Chain',nativeCurrency:{name:'ETH',symbol:'ETH',decimals:18},rpcUrls:[RPC],blockExplorerUrls:['https://rh-scan.com']}]})}else throw e}
  document.getElementById('who').textContent=acct;document.getElementById('m').disabled=false;document.getElementById('cl').disabled=false;log('connected '+acct);stats();pending();
}
async function commit(){
  const v=BigInt(Math.round(parseFloat(document.getElementById('amt').value)*1e6))*BigInt(1e12);
  const h=await window.ethereum.request({method:'eth_sendTransaction',params:[{from:acct,to:VAULT,value:'0x'+v.toString(16),data:'0x4f60dbaf'+pad(0)}]});
  log('commit sent '+h+' — claim in ~2–3 min');
}
async function pending(){
  if(!acct)return;const n=Number(big(await call(VAULT,'0x9123988b')));const mine=[];
  for(let i=Math.max(0,n-60);i<n;i++){const c=await call(VAULT,'0xc7c4a615'+pad(i));const user='0x'+c.slice(26,66);const claimed=big('0x'+c.slice(2+64*3,2+64*4))!==0n;
    if(user.toLowerCase()===acct.toLowerCase()&&!claimed){const e=await call(VAULT,'0x074bb1ec'+pad(i));mine.push({i,e,ready:big(e)!==(2n**256n-1n)})}}
  document.getElementById('pend').textContent=mine.length?`${mine.length} pending, ${mine.filter(x=>x.ready).length} ready`:'no pending commits';
  return mine;
}
async function claim(){
  const mine=(await pending())||[];let did=0;
  for(const m of mine.filter(x=>x.ready)){const h=await window.ethereum.request({method:'eth_sendTransaction',params:[{from:acct,to:VAULT,data:'0xc3490263'+pad(m.i)+m.e.slice(2)}]});log('claim sent '+h);did++}
  if(!did)log('nothing ready yet — wait for the next rebalance after your 2-minute window');
}
document.getElementById('c').onclick=()=>connect().catch(e=>log('error: '+(e.message||e)));
document.getElementById('m').onclick=()=>commit().catch(e=>log('error: '+(e.message||e)));
document.getElementById('cl').onclick=()=>claim().catch(e=>log('error: '+(e.message||e)));
stats();setInterval(()=>{stats();pending()},20000);
</script></body></html>"""
try:  # full vault UI (long / short / burn / claim / redeem) lives in vault_page.html; falls back to the inline long-only page
    LONG_PAGE = open(os.path.join(HERE, "vault_page.html")).read()
except FileNotFoundError:
    pass
try:
    LIVE_PAGE = open(os.path.join(HERE, "live_page.html")).read()
except FileNotFoundError:
    LIVE_PAGE = "<p>live_page.html missing</p>"
try:
    HOW_PAGE = open(os.path.join(HERE, "how_page.html")).read()
except FileNotFoundError:
    HOW_PAGE = "<p>how_page.html missing</p>"
HOW_PAGE = (HOW_PAGE.replace("__SYM__", _SYM).replace("__VAULT__", DEP["pool"]).replace("__LPONS__", DEP.get("longToken_lPONS", ""))
            .replace("__SPONS__", DEP["shortToken_sPONS"]).replace("__COIN__", DEP.get("coin", TSPONS)).replace("__BACKING__", DEP.get("backing", "")))
LIVE_PAGE = (LIVE_PAGE.replace("__SYM__", _SYM).replace("__VAULT__", DEP["pool"]).replace("__LPONS__", DEP.get("longToken_lPONS", ""))
             .replace("__SPONS__", DEP["shortToken_sPONS"]).replace("__COIN__", DEP.get("coin", TSPONS)).replace("__BACKING__", DEP.get("backing", "")))
LONG_PAGE = (LONG_PAGE.replace("__SYM__", _SYM).replace("__VAULT__", DEP["pool"]).replace("__LPONS__", DEP.get("longToken_lPONS", ""))
             .replace("__SPONS__", DEP["shortToken_sPONS"]).replace("__COIN__", DEP.get("coin", TSPONS)).replace("__BACKING__", DEP.get("backing", "")))

if __name__ == "__main__":
    if os.path.exists(HIST):
        try: history.extend(json.load(open(HIST)))
        except Exception: pass
    if not history and DEP_PATH.endswith("deployment.json"): seed_from_tracker()  # only the original test deployment shares perp_tracker.out
    threading.Thread(target=poller, daemon=True).start()
    threading.Thread(target=event_poller, daemon=True).start()
    print(f"sPONS dashboard on http://localhost:{PORT}  ({len(history)} history points)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
