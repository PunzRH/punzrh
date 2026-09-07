#!/usr/bin/env python3
"""
PUNZ watchdog — runs every 5 minutes (launchd). Pings James's PRIVATE Telegram (TG_BOT_TOKEN/TG_CHAT_ID in .env) when:
  * the keeper log has no rebalance in the last 6 minutes (keeper dead / Mac asleep)
  * the dashboard (localhost:8765/metrics) is down or stale (> 3 min)
  * the public tunnel (live.punzrh.com/metrics) is unreachable
  * the sPONS peg is > 4% off NAV for two consecutive checks
  * the ops wallet is below 0.01 ETH
  * the v2 short is within 12% of its liquidation price
Each condition alerts once, then again only after it recovers (state in punz_watchdog_state.json). Never posts to the public channel.
"""
import json, os, re, time, urllib.request, urllib.parse
HERE = os.path.dirname(os.path.abspath(__file__))
def _env(p):
    try:
        for ln in open(p):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln: k, v = ln.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError: pass
_env(os.path.join(HERE, ".env")); _env(os.path.expanduser("~/pons-sniper/.env"))
TOK, CHAT = os.environ.get("TG_BOT_TOKEN"), os.environ.get("TG_CHAT_ID")
STATE = os.path.join(HERE, "punz_watchdog_state.json")
try: state = json.load(open(STATE))
except Exception: state = {}
def tg(msg):
    if not (TOK and CHAT): return
    try: urllib.request.urlopen(urllib.request.Request(f"https://api.telegram.org/bot{TOK}/sendMessage", data=urllib.parse.urlencode({"chat_id": CHAT, "text": msg}).encode()), timeout=15)
    except Exception: pass
def flag(key, bad, msg_bad, msg_ok=None):
    was = state.get(key, False)
    if bad and not was: tg("🚨 PUNZ watchdog: " + msg_bad)
    if not bad and was and msg_ok: tg("✅ PUNZ watchdog: " + msg_ok)
    state[key] = bad
now = time.time()
# 1. keeper alive?
try:
    lines = open(os.path.join(HERE, "perp_keeper_punz.out"), "rb").read()[-20000:].decode(errors="ignore").splitlines()
    last = next((l for l in reversed(lines) if "rebalance" in l or "heartbeat" in l), "")
    m = re.match(r"\[(\d\d):(\d\d):(\d\d)\]", last)
    if m:
        lt = time.localtime(now); age = (lt.tm_hour * 3600 + lt.tm_min * 60 + lt.tm_sec) - (int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)))
        if age < -3600: age += 86400
        flag("keeper", age > 360, f"keeper silent for {age//60} min (last: {last[:80]})", "keeper is back")
except Exception as e: flag("keeper", True, f"keeper log unreadable: {e}")
# 2. dashboard + 3. tunnel + 5/6 numbers
def getj(url):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (punz-watchdog)"}), timeout=20))   # Cloudflare 403s the default Python UA
try:
    m = getj("http://localhost:8765/metrics"); flag("dash", now - m.get("updatedAt", 0) > 180, "dashboard stale/down", "dashboard back")
    liq, mark = m.get("lighter_liq"), (m.get("lighter_entry") or 0) + ((m.get("lighter_upnl") or 0) / abs(m.get("lighter_position_pons") or 1))
    if liq and mark: flag("liq", (liq - mark) / mark < 0.12, f"v2 short within {100*(liq-mark)/mark:.0f}% of liquidation (mark {mark:.4f}, liq {liq:.4f})", "v2 short back above 12% from liquidation")
except Exception as e: flag("dash", True, f"dashboard unreachable: {str(e)[:60]}", "dashboard back")
try: getj("https://live.punzrh.com/metrics"); flag("tunnel", False, "", "public site back")
except Exception as e: flag("tunnel", True, f"live.punzrh.com unreachable: {str(e)[:60]}", "public site back")
# 4. peg
try:
    pl = [l for l in lines if "peg | sPONS/NAV" in l][-2:]
    rs = [float(re.search(r"-> ([0-9.]+)", l).group(1)) for l in pl]
    flag("peg", len(rs) == 2 and all(abs(r - 1) > 0.04 for r in rs), f"sPONS peg off NAV: {rs}", "peg back within band")
except Exception: pass
# 5. ops gas
try:
    from web3 import Web3
    w3 = Web3(Web3.HTTPProvider(os.environ["RH_RPC_URL"], request_kwargs={"timeout": 20, "headers": {"User-Agent": "Mozilla/5.0"}}))
    bal = w3.eth.get_balance("0xfCBa0Dcb1668f94fF1cef112D04a4D2F3A537ae5") / 1e18
    flag("gas", bal < 0.01, f"ops wallet low: {bal:.4f} ETH — top up 0xfCBa0Dcb1668f94fF1cef112D04a4D2F3A537ae5", "ops wallet funded")
except Exception: pass
json.dump(state, open(STATE, "w"))
