#!/usr/bin/env python3
"""
PUNZ public proof feed → Telegram channel.
Reads the dashboard's /events (real on-chain events) and posts the ones worth a message:
  harvest (fees → short + burn), donate (peg-bot profit → Backing), redeem, vault mints/burns by users,
  big trades (≥ BIG_ETH), and an hourly summary (buys/sells/burned/backing/floor/PONS vs sPONS).
Config (env or ~/backpack-watcher/.env): TG_BOT_TOKEN, TG_FEED_CHAT (e.g. @punzrh_live). DRY=1 prints instead of posting.
    cd ~/backpack-watcher && TG_FEED_CHAT=@punzrh_live nohup caffeinate -i python3 -u tg_feed.py >> tg_feed.out 2>&1 &
"""
import json, os, time, datetime, urllib.request, urllib.parse

HOME = os.path.expanduser("~")
for p in (os.path.join(HOME, "backpack-watcher", ".env"), os.path.join(HOME, "pons-sniper", ".env")):
    try:
        for ln in open(p):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError: pass
TOK = os.environ.get("TG_FEED_TOKEN") or os.environ["TG_BOT_TOKEN"]; CHAT = os.environ.get("TG_FEED_CHAT", ""); DRY = os.environ.get("DRY") == "1"
DASH = os.environ.get("DASH_URL", "http://localhost:8765"); BIG_ETH = float(os.environ.get("BIG_ETH", "0.25"))
SYM = "PUNZ"; SCAN = "https://rh-scan.com/tx/"
STATE = os.path.join(HOME, "backpack-watcher", "tg_feed_state.json")

def get(path):
    return json.load(urllib.request.urlopen(DASH + path, timeout=20))
def post(text):
    if DRY or not CHAT: print("[dry]", text.replace("\n", " | ")[:200], flush=True); return
    body = json.dumps({"chat_id": CHAT, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(f"https://api.telegram.org/bot{TOK}/sendMessage", data=body, headers={"Content-Type": "application/json"}), timeout=15)
    except Exception as e:
        print("tg fail:", str(e)[:120], flush=True)
def link(tx): return f'<a href="{SCAN}{tx}">tx</a>'
def now(): return datetime.datetime.now().strftime("%H:%M:%S")

def fmt(e):
    k = e["kind"]
    if k == "harvest":
        # only the meaningful harvests get their own message; the small ones roll into the hourly summary
        if e.get("eth_instant", 0) + e.get("eth_vault", 0) < float(os.environ.get("HARVEST_MIN_ETH", "0.02")) and e.get("burned", 0) < float(os.environ.get("HARVEST_MIN_BURN", "150000")):
            return None
        parts = []
        if e.get("spons"): parts.append(f"{e['eth_instant']:.4f} ETH → {e['spons']:.2f} sPONS bought")
        if e.get("eth_vault"): parts.append(f"{e['eth_vault']:.4f} ETH → sPONS minted at NAV")
        if e.get("burned"): parts.append(f"🔥 {e['burned']:,.0f} {SYM} burned")
        return ("⚙️ <b>Harvest</b> · " + " · ".join(parts) + f" {link(e['tx'])}") if parts else None
    if k == "donate": return f"💝 <b>Peg bot → holders</b> · {e['spons']:.2f} sPONS sent to Backing (floor up for everyone) {link(e['tx'])}"
    if k == "redeem": return f"🏦 <b>Redeem</b> · {e['coin']:,.0f} {SYM} burned → {e['spons']:.3f} sPONS paid out {link(e['tx'])}"
    if k == "commit":
        side = "SHORT" if e.get("side") else "LONG"
        return f"⚖️ <b>Vault</b> · someone {'exits' if e.get('burn') else 'enters'} the {side} side {link(e['tx'])}"
    if k in ("buy", "sell") and e.get("eth", 0) >= BIG_ETH:
        return (f"🟢 <b>Big buy</b> · {e['coin']:,.0f} {SYM} for {e['eth']:.3f} ETH → 3% to the short {link(e['tx'])}" if k == "buy"
                else f"🔴 <b>Big sell</b> · {e['coin']:,.0f} {SYM} for {e['eth']:.3f} ETH → 3% burned {link(e['tx'])}")
    return None

def summary(evs, since):
    m = get("/metrics"); h = get("/data"); b, n = (h[0], h[-1]) if h else ({}, {})
    win = [e for e in evs if e["t"] >= since]
    buys = [e for e in win if e["kind"] == "buy"]; sells = [e for e in win if e["kind"] == "sell"]
    burned = sum(e.get("burned", 0) for e in win if e["kind"] == "harvest"); don = sum(e.get("spons", 0) for e in win if e["kind"] == "donate")
    pons = (n["pons"] / b["pons"] - 1) * 100 if h else 0; sp = (n["nav_s"] / b["nav_s"] - 1) * 100 if h else 0
    backed = 100 * m["backingPerPunzEth"] / m["marketPriceEth"] if m.get("marketPriceEth") else 0
    return (f"📊 <b>{SYM} hourly</b>\n"
            f"buys {len(buys)} ({sum(e['eth'] for e in buys):.2f} ETH) · sells {len(sells)} ({sum(e['eth'] for e in sells):.2f} ETH)\n"
            f"🔥 burned this hour {burned:,.0f} · total {m.get('burned', 0)/1e6:.1f}M\n"
            f"🏦 Backing {m.get('sponsBacking', 0):,.0f} sPONS · fees→short {m.get('feesToShortEth', 0):.3f} ETH · bot donated {don:.1f} sPONS\n"
            f"floor = {backed:.2f}% of price · PONS {pons:+.2f}% / sPONS {sp:+.2f}% since launch\n"
            f"vault long {n.get('long_bal', 0):.2f} / short {n.get('short_bal', 0):.2f} ETH · owner 0x0\n"
            f"live.punzrh.com/live")

def main():
    try: st = json.load(open(STATE))
    except Exception: st = {"seen": [], "last_summary": time.time()}
    seen = set(st["seen"]); first = not st["seen"]
    print(f"tg feed → {CHAT or '(dry)'} | poll 15s", flush=True)
    while True:
        try:
            evs = get("/events")
            for e in evs:
                key = f"{e['tx']}:{e['kind']}:{e.get('msg','')[:40]}"
                if key in seen: continue
                seen.add(key)
                if first: continue  # don't replay history on first start
                t = fmt(e)
                if t: post(t); print(f"[{now()}] {t[:90]}", flush=True); time.sleep(1)
            first = False
            if time.time() - st["last_summary"] >= 3600:
                post(summary(evs, st["last_summary"])); st["last_summary"] = time.time(); print(f"[{now()}] hourly summary posted", flush=True)
            st["seen"] = list(seen)[-2000:]; json.dump(st, open(STATE, "w"))
        except Exception as ex:
            print(f"[{now()}] error: {str(ex)[:120]}", flush=True)
        time.sleep(15)

if __name__ == "__main__":
    main()
