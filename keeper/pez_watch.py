#!/usr/bin/env python3
"""
Watch the PEZ perp vault (PezPerpVault clone 0xe8af… created by Loracle's wallet on 7 Sep) and ping James's PRIVATE Telegram the
moment it goes live: Lighter account created, first deposit, ETH arriving, a keeper action, or any new tx from Loracle / the keeper.
Then, once it has an account, report its Lighter position on each change. launchd runs this every 2 minutes.
"""
import json, os, time, urllib.request, urllib.parse
HERE = os.path.dirname(os.path.abspath(__file__))
def _env(p):
    try:
        for ln in open(p):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln: k, v = ln.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError: pass
_env(os.path.join(HERE, ".env")); _env(os.path.expanduser("~/pons-sniper/.env"))
from web3 import Web3
w3 = Web3(Web3.HTTPProvider(os.environ["RH_RPC_URL"], request_kwargs={"timeout": 20, "headers": {"User-Agent": "Mozilla/5.0"}}))
VAULT = Web3.to_checksum_address("0xe8af661c277e3aebb3f4bfeb11bf25c31ad2c2d1"); LORACLE = Web3.to_checksum_address("0xE2a0cC663aCFE5D7A9Cb82A743383297597A8fF3"); KEEPER = Web3.to_checksum_address("0xE5F40f084f910C941c659D630299b46F100565fC")
STATE = os.path.join(HERE, "pez_watch_state.json")
try: st = json.load(open(STATE))
except Exception: st = {}
def tg(msg):
    tok, chat = os.environ.get("TG_BOT_TOKEN"), os.environ.get("TG_CHAT_ID")
    if tok and chat:
        try: urllib.request.urlopen(urllib.request.Request(f"https://api.telegram.org/bot{tok}/sendMessage", data=urllib.parse.urlencode({"chat_id": chat, "text": msg}).encode()), timeout=15)
        except Exception: pass
def call(sel): return int.from_bytes(w3.eth.call({"to": VAULT, "data": sel}), "big")
now = {"account": call("0x9e9cb275"), "deposited": call(Web3.keccak(text="totalDeposited()")[:4]), "lastKeeper": call(Web3.keccak(text="lastKeeperAction()")[:4]),
       "eth": w3.eth.get_balance(VAULT), "loracle_nonce": w3.eth.get_transaction_count(LORACLE), "keeper_nonce": w3.eth.get_transaction_count(KEEPER)}
msgs = []
if st:
    if now["account"] and not st.get("account"): msgs.append(f"PEZ vault is LIVE on Lighter: account #{now['account']} created (first deposit done).")
    if now["deposited"] > st.get("deposited", 0): msgs.append(f"PEZ vault deposited: total {now['deposited']/1e6:.2f} USDG.")
    if now["eth"] > st.get("eth", 0): msgs.append(f"ETH arrived in the PEZ vault: {now['eth']/1e18:.4f} ETH (creator fees routed).")
    if now["loracle_nonce"] > st.get("loracle_nonce", 0): msgs.append(f"Loracle's wallet sent {now['loracle_nonce'] - st['loracle_nonce']} new tx(s): https://rh-scan.com/address/{LORACLE}")
    if now["keeper_nonce"] > st.get("keeper_nonce", 0): msgs.append(f"PEZ keeper wallet acted ({now['keeper_nonce'] - st['keeper_nonce']} tx): https://rh-scan.com/address/{KEEPER}")
    if now["lastKeeper"] != st.get("lastKeeper") and now["lastKeeper"]: msgs.append("PEZ vault keeper heartbeat/action recorded on-chain.")
    if now["account"]:
        try:
            a = json.load(urllib.request.urlopen(f"https://api.rh.lighter.xyz/api/v1/account?by=index&value={now['account']}", timeout=15))["accounts"][0]
            pos = next((p for p in a.get("positions", []) if float(p.get("position") or 0)), None)
            sig = f"{a.get('collateral')}|{pos['position'] if pos else 0}"
            if sig != st.get("sig"): msgs.append(f"PEZ vault Lighter account #{now['account']}: collateral {float(a.get('collateral') or 0):.2f} USDG, position {('SHORT ' if pos and str(pos.get('sign')).startswith('-') else 'LONG ') + pos['position'] + ' PONS @ ' + pos['avg_entry_price'] if pos else 'none'}")
            now["sig"] = sig
        except Exception: now["sig"] = st.get("sig")
if msgs: tg("👀 PEZ watch: " + " ".join(msgs))
json.dump(now, open(STATE, "w"))
