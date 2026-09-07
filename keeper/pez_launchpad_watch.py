#!/usr/bin/env python3
"""
Watch pez.family (api.pez.family/api/launches) + the PezPerpVaultFactory on-chain, and ping James's PRIVATE Telegram when:
  * a new launch appears whose deployer / creator-fee recipient is Loracle's wallet
  * any launch's creatorFeeRecipient changes to a PezPerpVault (a coin gets "integrated" with a perp vault)
  * PezPerpVaultFactory creates a new vault (createFor) for any token — with symbol, market, leverage
  * a launch named PEZ/LORACLE changes phase (graduation etc.)
launchd runs this every 2 minutes. State in pez_launchpad_state.json.
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
LORACLE = "0xe2a0cc663acfe5d7a9cb82a743383297597a8ff3"
FACTORY = Web3.to_checksum_address("0xDb8fcED0d6c8e631ce5b2cB3608420F564e069cD"); CREATED = "0xdf71cb677a8d6e7c12e19b998b4fe5b6b0e366bb25cb7b705e216ef660f578b6"
STATE = os.path.join(HERE, "pez_launchpad_state.json")
try: st = json.load(open(STATE))
except Exception: st = {}
def tg(msg):
    tok, chat = os.environ.get("TG_BOT_TOKEN"), os.environ.get("TG_CHAT_ID")
    if tok and chat:
        try: urllib.request.urlopen(urllib.request.Request(f"https://api.telegram.org/bot{tok}/sendMessage", data=urllib.parse.urlencode({"chat_id": chat, "text": msg, "disable_web_page_preview": "true"}).encode()), timeout=15)
        except Exception: pass
msgs = []
# ---- launchpad API
try:
    items = []; page = 1
    while True:   # paginated, 50 per page (288 launches on 7 Sep)
        d = json.load(urllib.request.urlopen(urllib.request.Request(f"https://api.pez.family/api/launches?page={page}", headers={"User-Agent": "Mozilla/5.0"}), timeout=20))
        items += d.get("items", []); total = d.get("total", 0)
        if page * d.get("pageSize", 50) >= total or page >= 20: break
        page += 1
    seen = st.get("launches", {}); cur = {}
    for it in items:
        tok = (it.get("token") or "").lower(); sym = it.get("symbol") or "?"
        rec = {"sym": sym, "deployer": (it.get("deployer") or "").lower(), "feeRecipient": (it.get("creatorFeeRecipient") or "").lower(), "phase": it.get("phaseLabel"), "mcap": round(it.get("marketCapUsd") or 0)}
        cur[tok] = rec
        if st.get("launches") is not None:
            old = seen.get(tok)
            loracle = rec["deployer"] == LORACLE or rec["feeRecipient"] == LORACLE
            if old is None and loracle: msgs.append(f"NEW LAUNCH by Loracle on pez.family: ${sym} {tok} phase {rec['phase']} https://pez.family/launchpad")
            elif old is None: pass  # other people's launches: not James's ask
            if old and old.get("feeRecipient") != rec["feeRecipient"]:
                code = len(w3.eth.get_code(Web3.to_checksum_address(rec["feeRecipient"]))) if rec["feeRecipient"].startswith("0x") and len(rec["feeRecipient"]) == 42 else 0
                msgs.append(f"${sym} creator-fee recipient changed → {rec['feeRecipient']} ({'contract' if code > 2 else 'wallet'}){' — likely a perp vault integration' if code == 45 or code > 2 else ''}")
            if old and old.get("phase") != rec["phase"] and (loracle or sym.upper() in ("PEZ", "LORACLE")): msgs.append(f"${sym} phase: {old.get('phase')} → {rec['phase']} (mcap ${rec['mcap']:,})")
    st["launches"] = cur
except Exception as e: st["api_err"] = str(e)[:80]
# ---- PEZ itself (not in /api/launches): the integration moment is creatorFeeRecipient flipping from Loracle's wallet to the vault
try:
    t = json.load(urllib.request.urlopen(urllib.request.Request("https://api.pez.family/api/tokens/0xa3602804e096cb73bd8344afc1ff3f3390b899c5", headers={"User-Agent": "Mozilla/5.0"}), timeout=20))
    rec = {"feeRecipient": (t.get("creatorFeeRecipient") or "").lower(), "phase": t.get("phaseLabel"), "mcap": round(t.get("marketCapUsd") or 0), "holders": t.get("holders")}
    old = st.get("pez")
    if old:
        if old["feeRecipient"] != rec["feeRecipient"]:
            msgs.append(f"PEZ creator fees now go to {rec['feeRecipient']}" + (" = the PEZ PERP VAULT. Integration is live: every PEZ creator fee now feeds the PONS short." if rec["feeRecipient"].startswith("0xe8af661c") else ""))
        if old["phase"] != rec["phase"]: msgs.append(f"PEZ phase {old['phase']} → {rec['phase']}")
    st["pez"] = rec
except Exception as e: st["pez_err"] = str(e)[:80]
# ---- on-chain: new perp vaults
try:
    head = w3.eth.block_number; frm = st.get("scanned", head - 3000) + 1
    logs = []
    while frm <= head:
        to = min(frm + 4999, head); logs += w3.eth.get_logs({"fromBlock": frm, "toBlock": to, "address": FACTORY, "topics": [CREATED]}); frm = to + 1
    for l in logs:
        tok = "0x" + l["topics"][1].hex()[-40:]; vault = "0x" + l["topics"][2].hex()[-40:]
        try: sym = w3.codec.decode(["string"], w3.eth.call({"to": Web3.to_checksum_address(tok), "data": bytes.fromhex("95d89b41")}))[0]
        except Exception: sym = tok[:10]
        who = w3.eth.get_transaction(l["transactionHash"])["from"].lower()
        msgs.append(f"NEW PERP VAULT created for ${sym} ({tok[:10]}) by {'LORACLE' if who == LORACLE else who[:10]} → vault {vault} https://rh-scan.com/tx/{l['transactionHash'].hex()}")
    st["scanned"] = head
except Exception as e: st["chain_err"] = str(e)[:80]
if msgs: tg("🧭 pez.family watch:\n" + "\n".join(msgs))
json.dump(st, open(STATE, "w"))
