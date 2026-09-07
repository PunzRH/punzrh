#!/usr/bin/env python3
"""
PonsPerpPool keeper — Robinhood Chain.

Calls `rebalance()` on the pool once per interval so the long/short pools track the PONS/WETH TWAP and
new epochs exist for commit claims. Also auto-claims the keeper wallet's own pending commits.
Reads the pool address from ~/pons-perp/deployment.json, key from LONG_PK in ~/pons-sniper/.env.

    cd ~/backpack-watcher && caffeinate -i python3 -u perp_keeper.py
"""
import json, os, time, datetime
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
_load_env(os.path.join(HOME, "pons-sniper", ".env"))
_load_env(os.path.join(HOME, "backpack-watcher", ".env"))

_load_env(os.environ.get("PERP_ENV", os.path.join(HOME, "pons-perp", ".env.dev")))  # DEV_PK for the real launch
_load_env(os.path.join(HOME, "pons-perp", ".env.ops"))  # KEEPER_PK: separate ops wallet (so terminals don't tag keeper txs as "dev")
DEP = json.load(open(os.environ.get("PERP_DEPLOYMENT", os.path.join(HOME, "pons-perp", "deployment.json"))))
POOL = Web3.to_checksum_address(DEP["pool"])
ABI = json.load(open(os.path.join(HOME, "pons-perp", "out", "PonsPerpPool.sol", "PonsPerpPool.json")))["abi"]
POLL = float(os.environ.get("PERP_KEEPER_POLL", "15"))

w3 = Web3(Web3.HTTPProvider(os.environ["RH_RPC_URL"], request_kwargs={"timeout": 30, "headers": {"User-Agent": "Mozilla/5.0"}}))
# key choice: KEEPER_PK (ops wallet) when USE_OPS_WALLET=1 and this is the real deployment; else the key matching the deployer
_use_ops = os.environ.get("USE_OPS_WALLET", "0") == "1" and os.environ.get("KEEPER_PK")
_cands = [k for k in (os.environ.get("PERP_PK"), os.environ.get("DEV_PK"), os.environ.get("LONG_PK")) if k]
acct = w3.eth.account.from_key(os.environ["KEEPER_PK"]) if _use_ops else \
       (next((w3.eth.account.from_key(k) for k in _cands if w3.eth.account.from_key(k).address.lower() == str(DEP.get("deployer", "")).lower()), None)
        or w3.eth.account.from_key(_cands[-1]))
pool = w3.eth.contract(address=POOL, abi=ABI)

def now(): return datetime.datetime.now().strftime("%H:%M:%S")

def send(fn, value=0):
    tx = fn.build_transaction({"from": acct.address, "value": value,
                               "nonce": w3.eth.get_transaction_count(acct.address),
                               "chainId": w3.eth.chain_id})
    gp = w3.eth.gas_price
    tx["maxFeePerGas"] = int(gp * 1.4); tx["maxPriorityFeePerGas"] = min(int(gp * 0.5) + 1, tx["maxFeePerGas"])
    tx.pop("gasPrice", None)
    tx["gas"] = int(w3.eth.estimate_gas(tx) * 1.3)
    s = acct.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(s.raw_transaction)
    rc = w3.eth.wait_for_transaction_receipt(h, timeout=120)
    return h.hex(), rc.status

def main():
    interval = pool.functions.rebalanceInterval().call()
    print(f"perp keeper | pool {POOL} | keeper {acct.address} | interval {interval}s | poll {POLL}s", flush=True)
    hb = time.time()
    # PEG=1: keep the public sPONS/ETH chart at NAV (live short index). Same wallet, same nonce stream.
    peg = None
    if os.environ.get("PEG") == "1" and DEP.get("spons_eth_pool"):
        import peg_keeper
        peg = peg_keeper.Peg(w3, acct.address, send, DEP); peg.ensure_approvals(); last_peg = 0
        print(f"peg keeper ON | sPONS/ETH pool {DEP['spons_eth_pool']} | band {peg_keeper.BAND_BPS} bps | every {os.environ.get('PEG_SECS', '60')}s", flush=True)
    # Backing v2 (Lighter short): harvest LP fees → fund the short → settle redeem claims. Permissionless calls; keeper pays gas.
    v2 = None
    if DEP.get("lighterBacking"):
        import lighter_keeper
        v2 = lighter_keeper.LighterKeeper(w3, send, DEP); last_v2 = 0
        print(f"v2 keeper ON | LighterBacking {DEP['lighterBacking']} | FeeFeeder {DEP.get('feeFeeder')}", flush=True)
    while True:
        try:
            if v2 and time.time() - last_v2 > float(os.environ.get("V2_SECS", "60")):
                last_v2 = time.time()
                try: v2.step()
                except Exception as ex: print(f"[{now()}] v2 error: {str(ex)[:120]}", flush=True)
            if peg and time.time() - last_peg > float(os.environ.get("PEG_SECS", "60")):
                last_peg = time.time()
                try: peg.step()
                except Exception as ex: print(f"[{now()}] peg error: {str(ex)[:120]}", flush=True)
            last = pool.functions.lastRebalance().call()
            if time.time() >= last + interval + 2:
                h, st = send(pool.functions.rebalance())
                lb, sb = pool.functions.longBal().call() / 1e18, pool.functions.shortBal().call() / 1e18
                px = pool.functions.lastPriceX96().call() * 1e18 / 2**96 / 1e18
                print(f"[{now()}] rebalance {'OK' if st == 1 else 'REVERTED'} {h[:12]}… | PONS {px:.8f} ETH | long {lb:.6f} short {sb:.6f} ETH", flush=True)
            # POONS v2: harvest LP fees into the short and settle matured backing commits (permissionless)
            if DEP.get("backing"):
                if "backing_c" not in globals():
                    globals()["backing_c"] = w3.eth.contract(address=Web3.to_checksum_address(DEP["backing"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "Backing.sol", "Backing.json")))["abi"])
                if time.time() - globals().get("last_harvest", 0) > float(os.environ.get("HARVEST_SECS", "600")):
                    globals()["last_harvest"] = time.time()
                    try:
                        h, st = send(backing_c.functions.harvest())
                        print(f"[{now()}] harvest {'OK' if st == 1 else 'REVERTED'} {h[:12]}… | ETH->short total {backing_c.functions.totalEthCommitted().call()/1e18:.6f} | sPONS backing {backing_c.functions.sponsBacking().call()/1e18:.4f}", flush=True)
                    except Exception as ex:
                        print(f"[{now()}] harvest skipped: {str(ex)[:80]}", flush=True)
                npend = backing_c.functions.pendingCount().call()
                matured = any(pool.functions.claimableEpoch(backing_c.functions.pendingCommits(i).call()).call() != 2**256 - 1 for i in range(npend))
                if matured:
                    try:
                        h, st = send(backing_c.functions.claim())
                        print(f"[{now()}] backing claim {'OK' if st == 1 else 'REVERTED'} {h[:12]}… | sPONS backing {backing_c.functions.sponsBacking().call()/1e18:.4f}", flush=True)
                    except Exception as ex:
                        print(f"[{now()}] backing claim skipped: {str(ex)[:80]}", flush=True)
            # auto-claim our own pending commits
            n = pool.functions.commitCount().call()
            for i in range(n):
                c = pool.functions.commits(i).call()  # (user, side, isBurn, claimed, time, amount)
                if c[0] == acct.address and not c[3]:
                    e = pool.functions.claimableEpoch(i).call()
                    if e != 2**256 - 1:
                        h, st = send(pool.functions.claim(i, e))
                        print(f"[{now()}] claimed commit {i} at epoch {e}: {'OK' if st == 1 else 'REVERTED'} {h[:12]}…", flush=True)
        except Exception as ex:
            print(f"[{now()}] error: {str(ex)[:160]}", flush=True)
        if time.time() - hb > 300:
            hb = time.time()
            try:
                print(f"[{now()}] heartbeat | epochs {pool.functions.epochCount().call()} | "
                      f"sPONS {pool.functions.sharePriceWei(1).call()/1e18:.8f} ETH | "
                      f"lPONS {pool.functions.sharePriceWei(0).call()/1e18:.8f} ETH", flush=True)
            except Exception:
                pass
        time.sleep(POLL)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nbye")
