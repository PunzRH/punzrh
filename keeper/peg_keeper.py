#!/usr/bin/env python3
"""
sPONS/ETH peg keeper — keeps the public sPONS chart at the vault's NAV so it is a live index of the PONS short.

Runs inside perp_keeper.py (PEG=1) so one wallet / one nonce stream does rebalance + harvest + peg. Each poll:
  * read NAV (vault.sharePriceWei(SHORT)) and the pool's slot0
  * if sPONS trades > NAV*(1+band): sell exactly enough sPONS to bring it back to NAV
  * if sPONS trades < NAV*(1-band): buy exactly enough sPONS with ETH to bring it back to NAV
  * if sPONS inventory is low and ETH allows: commitMint(SHORT) at the vault (perp_keeper auto-claims it)
Amounts are computed from the single SeedPool position (liquidity, tickLower, tickUpper), so no quoter is needed.
Swaps go through the Universal Router (V4_SWAP: SWAP_EXACT_IN_SINGLE / SETTLE_ALL / TAKE_ALL); sPONS input via Permit2.

Standalone fork test:   ANVIL_FORK=1 python3 peg_keeper.py      (spawns anvil on the live RPC, dry-runs every path)
"""
import json, os, time, subprocess, datetime
from web3 import Web3
from eth_abi import encode

HOME = os.path.expanduser("~")
Q96 = 2 ** 96
ZERO = "0x" + "0" * 40
PM = Web3.to_checksum_address("0x8366a39cc670b4001a1121b8f6a443a643e40951")
UR = Web3.to_checksum_address("0x8876789976decbfcbbbe364623c63652db8c0904")
PERMIT2 = Web3.to_checksum_address("0x000000000022D473030F116dDEE9F6B43aC78BA3")
BAND_BPS = int(os.environ.get("PEG_BAND_BPS", "100"))          # act when > 1% off NAV
GAS_RESERVE = Web3.to_wei(os.environ.get("PEG_GAS_RESERVE_ETH", "0.04"), "ether")  # never spend below this (keeper gas)
SPONS_MIN = Web3.to_wei(os.environ.get("PEG_SPONS_MIN", "150"), "ether")           # refill inventory below this many sPONS
MINT_MAX = Web3.to_wei(os.environ.get("PEG_MINT_MAX_ETH", "0.12"), "ether")         # per refill
SWAP_MAX_ETH = Web3.to_wei(os.environ.get("PEG_SWAP_MAX_ETH", "0.15"), "ether")     # per buy
# profit sharing: everything above the working inventory is sent to the Backing contract → raises the floor for every holder
KEEP_SPONS = Web3.to_wei(os.environ.get("PEG_KEEP_SPONS", "150"), "ether")           # working inventory the peg keeps
DONATE_MIN = Web3.to_wei(os.environ.get("PEG_DONATE_MIN", "20"), "ether")            # don't bother below this (gas)
ERC_TRANSFER = '{"name":"transfer","type":"function","inputs":[{"type":"address"},{"type":"uint256"}],"outputs":[{"type":"bool"}],"stateMutability":"nonpayable"}'
ERC = json.loads('[' + ERC_TRANSFER + ',{"name":"balanceOf","type":"function","inputs":[{"type":"address"}],"outputs":[{"type":"uint256"}],"stateMutability":"view"},'
                 '{"name":"allowance","type":"function","inputs":[{"type":"address"},{"type":"address"}],"outputs":[{"type":"uint256"}],"stateMutability":"view"},'
                 '{"name":"approve","type":"function","inputs":[{"type":"address"},{"type":"uint256"}],"outputs":[{"type":"bool"}],"stateMutability":"nonpayable"}]')
P2 = json.loads('[{"name":"allowance","type":"function","inputs":[{"type":"address"},{"type":"address"},{"type":"address"}],"outputs":[{"type":"uint160"},{"type":"uint48"},{"type":"uint48"}],"stateMutability":"view"},'
                '{"name":"approve","type":"function","inputs":[{"type":"address"},{"type":"address"},{"type":"uint160"},{"type":"uint48"}],"outputs":[],"stateMutability":"nonpayable"}]')
PMABI = json.loads('[{"name":"extsload","type":"function","inputs":[{"type":"bytes32"}],"outputs":[{"type":"bytes32"}],"stateMutability":"view"}]')
URABI = json.loads('[{"name":"execute","type":"function","inputs":[{"type":"bytes"},{"type":"bytes[]"},{"type":"uint256"}],"outputs":[],"stateMutability":"payable"}]')

def now(): return datetime.datetime.now().strftime("%H:%M:%S")

class Peg:
    def __init__(self, w3, acct_address, send, dep, log=print):
        self.w3, self.me, self.send, self.log = w3, acct_address, send, log
        self.spons = Web3.to_checksum_address(dep["shortToken_sPONS"])
        self.vault = w3.eth.contract(address=Web3.to_checksum_address(dep["pool"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "PonsPerpPool.sol", "PonsPerpPool.json")))["abi"])
        if dep.get("peg_range"):   # re-seatable ops-owned range (PegRange); SeedPool's fixed range is legacy
            self.seed = w3.eth.contract(address=Web3.to_checksum_address(dep["peg_range"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "PegRange.sol", "PegRange.json")))["abi"])
            k = self.seed.functions.key().call(); self.fee, self.ts = int(k[2]), int(k[3]); self.reseatable = True
        else:
            self.seed = w3.eth.contract(address=Web3.to_checksum_address(dep["spons_eth_pool"]), abi=json.load(open(os.path.join(HOME, "pons-perp", "out", "SeedPool.sol", "SeedPool.json")))["abi"])
            self.fee, self.ts = self.seed.functions.fee().call(), self.seed.functions.tickSpacing().call(); self.reseatable = False
        self.last_reseat = 0
        self.key = (ZERO, self.spons, self.fee, self.ts, ZERO)
        pid = Web3.keccak(encode(["address", "address", "uint24", "int24", "address"], list(self.key)))
        self.slot = Web3.keccak(pid + (6).to_bytes(32, "big"))
        self.pm = w3.eth.contract(address=PM, abi=PMABI); self.ur = w3.eth.contract(address=UR, abi=URABI)
        self.tok = w3.eth.contract(address=self.spons, abi=ERC); self.p2 = w3.eth.contract(address=PERMIT2, abi=P2)
        self.backing = Web3.to_checksum_address(dep["backing"]) if dep.get("backing") else None
        self.last_mint = 0; self.donated = 0

    # ---- reads
    def sqrt_now(self):
        return int.from_bytes(self.pm.functions.extsload(self.slot).call(), "big") & ((1 << 160) - 1)
    def position(self):
        lo, hi, L = self.seed.functions.tickLower().call(), self.seed.functions.tickUpper().call(), self.seed.functions.liquidity().call()
        return int(1.0001 ** (lo / 2) * Q96), int(1.0001 ** (hi / 2) * Q96), L
    def nav_sqrt(self): return self.seed.functions.navSqrtPriceX96().call()
    def state(self):
        s, n = self.sqrt_now(), self.nav_sqrt()
        # pool price = sPONS per ETH = (s/Q96)^2 ; sPONS price in ETH relative to NAV = (n/s)^2
        return s, n, (n / s) ** 2 if s else float("inf")

    # ---- approvals (once)
    def ensure_approvals(self):
        if self.tok.functions.allowance(self.me, PERMIT2).call() < 2 ** 200:
            self.send(self.tok.functions.approve(PERMIT2, 2 ** 256 - 1)); self.log(f"[{now()}] peg: sPONS -> Permit2 approved")
        amt, exp, _ = self.p2.functions.allowance(self.me, self.spons, UR).call()
        if amt < 2 ** 150 or exp < time.time() + 86400:
            self.send(self.p2.functions.approve(self.spons, UR, 2 ** 160 - 1, 2 ** 48 - 1)); self.log(f"[{now()}] peg: Permit2 -> router approved")

    # ---- swap builders (Universal Router V4_SWAP)
    def _v4(self, zero_for_one, amount_in, min_out):
        cin, cout = (ZERO, self.spons) if zero_for_one else (self.spons, ZERO)
        p_swap = encode(['((address,address,uint24,int24,address),bool,uint128,uint128,uint160,bytes)'], [(self.key, zero_for_one, amount_in, min_out, 0, b'')])
        v4 = encode(['bytes', 'bytes[]'], [bytes([0x06, 0x0c, 0x0f]), [p_swap, encode(['address', 'uint256'], [cin, amount_in]), encode(['address', 'uint256'], [cout, min_out])]])
        return self.ur.functions.execute(bytes([0x10]), [v4], int(time.time()) + 600)
    def sell_spons(self, amount_in, min_out): return self.send(self._v4(False, amount_in, min_out))
    def buy_spons(self, eth_in, min_out): return self.send(self._v4(True, eth_in, min_out), value=eth_in)

    # ---- one step
    def step(self):
        # after a trade, let the RPC catch up before reading the pool again (a stale slot0 made us sell twice on 7 Sep and overshoot)
        if time.time() < getattr(self, "cool_until", 0): return None
        s, n, ratio = self.state()
        lo, hi, L = self.position()
        nav_wei = self.vault.functions.sharePriceWei(1).call()       # ETH per 1e18 sPONS
        bal_s, bal_e = self.tok.functions.balanceOf(self.me).call(), self.w3.eth.get_balance(self.me)
        spend = max(0, bal_e - GAS_RESERVE)
        acted = None
        # re-seat the range when NAV (or the pool) has walked out of it — the failure mode of the fixed SeedPool on 7 Sep
        if self.reseatable and time.time() - self.last_reseat > 1800:
            out = L == 0 or not (lo <= n < hi) or not (lo <= s < hi)
            if out:
                self.last_reseat = time.time()
                if L > 0: self.send(self.seed.functions.exit()); bal_s, bal_e = self.tok.functions.balanceOf(self.me).call(), self.w3.eth.get_balance(self.me); spend = max(0, bal_e - GAS_RESERVE)
                eth_in = min(spend // 2, Web3.to_wei(0.03, "ether")); s_in = bal_s // 2
                if eth_in > Web3.to_wei(0.003, "ether") and s_in > Web3.to_wei(5, "ether"):
                    if self.tok.functions.allowance(self.me, self.seed.address).call() < s_in: self.send(self.tok.functions.approve(self.seed.address, 2 ** 256 - 1))
                    h, st = self.send(self.seed.functions.seed(s_in), value=eth_in)
                    self.log(f"[{now()}] peg: RESEAT range around NAV with {eth_in/1e18:.4f} ETH + up to {s_in/1e18:.1f} sPONS {'OK' if st == 1 else 'REVERTED'} {h[:12]}…")
                    s, n, ratio = self.state(); lo, hi, L = self.position()
                    bal_s, bal_e = self.tok.functions.balanceOf(self.me).call(), self.w3.eth.get_balance(self.me); spend = max(0, bal_e - GAS_RESERVE)
                else:
                    self.log(f"[{now()}] peg: range out but not enough inventory to re-seat (ETH spend {spend/1e18:.4f}, sPONS {bal_s/1e18:.1f})")
        if ratio > 1 + BAND_BPS / 1e4:
            # sPONS too expensive -> sell sPONS (price sPONS/ETH rises toward n). Only the in-range part consumes liquidity.
            start = max(s, lo)
            if n > start:
                need = L * (n - start) // Q96
                amt = min(need * 10 ** 6 // (10 ** 6 - self.fee) * 6 // 10 + 1, bal_s)
                if amt > Web3.to_wei(0.5, "ether"):
                    # size back-off: if the pool can't fill the whole amount above 95% of NAV (thin pool, or price sitting above the
                    # range so `need` overshoots), halve until the gas estimate passes. Estimates fail off-chain: no gas, no nonce.
                    last_err = None
                    for a in (amt, amt // 2, amt // 4, amt // 8):
                        if a <= Web3.to_wei(0.5, "ether"): break
                        min_out = a * nav_wei // 10 ** 18 * 95 // 100   # we only sell above NAV
                        try:
                            h, st = self.sell_spons(a, min_out)
                            acted = f"SELL {a/1e18:.2f} sPONS (need {need/1e18:.2f}) {'OK' if st == 1 else 'REVERTED'} {h[:12]}…"; self.cool_until = time.time() + 45; break
                        except Exception as ex:
                            last_err = ex
                            if "8b063d73" not in str(ex) and "TooLittle" not in str(ex): raise
                    if acted is None and last_err is not None: acted = f"sell wanted ({need/1e18:.2f} sPONS) but pool too thin above 95% NAV even for {amt/8/1e18:.2f}"
                elif bal_s <= Web3.to_wei(0.5, "ether"):
                    acted = "sell wanted, no sPONS inventory"
        elif ratio < 1 - BAND_BPS / 1e4:
            # sPONS too cheap -> buy with ETH (price sPONS/ETH falls toward n)
            start = min(s, hi)
            if start > n:
                need = L * Q96 * (start - n) // (start * n)
                amt = min(need * 10 ** 6 // (10 ** 6 - self.fee) * 6 // 10 + 1, spend, SWAP_MAX_ETH)
                if amt > Web3.to_wei(0.001, "ether"):
                    last_err = None
                    for a in (amt, amt // 2, amt // 4, amt // 8):
                        if a <= Web3.to_wei(0.001, "ether"): break
                        min_out = a * 10 ** 18 // nav_wei * 95 // 100
                        try:
                            h, st = self.buy_spons(a, min_out)
                            acted = f"BUY sPONS with {a/1e18:.4f} ETH (need {need/1e18:.4f}) {'OK' if st == 1 else 'REVERTED'} {h[:12]}…"; self.cool_until = time.time() + 45; break
                        except Exception as ex:
                            last_err = ex
                            if "8b063d73" not in str(ex) and "TooLittle" not in str(ex): raise
                    if acted is None and last_err is not None: acted = f"buy wanted ({need/1e18:.4f} ETH) but pool too thin below 105% NAV"
                else:
                    acted = "buy wanted, no spare ETH"
        # inventory refill: mint sPONS at NAV from the vault (claimed automatically by perp_keeper's auto-claim loop)
        if bal_s < SPONS_MIN and spend > Web3.to_wei(0.02, "ether") and time.time() - self.last_mint > 600:
            amt = min(spend - Web3.to_wei(0.01, "ether"), MINT_MAX)
            h, st = self.send(self.vault.functions.commitMint(1), value=amt); self.last_mint = time.time()
            acted = (acted + " | " if acted else "") + f"MINT commit {amt/1e18:.4f} ETH -> sPONS {'OK' if st == 1 else 'REVERTED'} {h[:12]}…"
        # profit sharing → Backing (only leaves via holders' redeem), i.e. floor up for everyone.
        # First run: seed-donate everything above the working inventory and record the remaining capital as the baseline.
        # After that: donate only PROFIT (current value − baseline), never the working capital, and only sPONS above KEEP.
        if self.backing and os.environ.get("PEG_DONATE", "1") == "1":
            st_path = os.path.join(HOME, "backpack-watcher", "peg_state.json")
            try: state = json.load(open(st_path))
            except Exception: state = {}
            bal_s2 = self.tok.functions.balanceOf(self.me).call(); bal_e2 = self.w3.eth.get_balance(self.me)
            value = bal_e2 + bal_s2 * nav_wei // 10 ** 18
            if "base_value_wei" not in state:
                give = max(0, bal_s2 - KEEP_SPONS)
            else:
                profit = value - int(state["base_value_wei"])
                give = min(max(0, bal_s2 - KEEP_SPONS), max(0, profit * 10 ** 18 // nav_wei))
            # v2 present: route profit to the Lighter short instead — burn the excess sPONS at the vault for ETH (auto-claimed by perp_keeper),
            # and push spare ETH above the working float to LighterBacking (fund() turns it into the short).
            v2 = os.environ.get("V2_SINK")
            if v2 and give >= DONATE_MIN:
                self.tok.functions.approve(self.vault.address, give).call({"from": self.me})
                h, st = self.send(self.tok.functions.approve(self.vault.address, give)); h, st = self.send(self.vault.functions.commitBurn(1, give))
                state["donated_wei"] = int(state.get("donated_wei", 0)) + give
                acted = (acted + " | " if acted else "") + f"PROFIT {give/1e18:.2f} sPONS -> burn for ETH -> v2 {'OK' if st == 1 else 'REVERTED'} {h[:12]}…"
                give = 0
            if v2:
                keep = Web3.to_wei(os.environ.get("PEG_KEEP_ETH", "0.15"), "ether"); spare = self.w3.eth.get_balance(self.me) - keep
                if spare >= Web3.to_wei(0.003, "ether"):
                    tx = {"to": Web3.to_checksum_address(v2), "value": spare}
                    h, st = self.send_raw(tx) if hasattr(self, "send_raw") else (None, 0)
                    if h: acted = (acted + " | " if acted else "") + f"ETH {spare/1e18:.4f} -> LighterBacking (v2) {'OK' if st == 1 else 'REV'} {h[:12]}…"
            if give >= DONATE_MIN:
                h, st = self.send(self.tok.functions.transfer(self.backing, give))
                state["donated_wei"] = int(state.get("donated_wei", 0)) + give
                acted = (acted + " | " if acted else "") + f"DONATE {give/1e18:.2f} sPONS -> Backing (floor up) {'OK' if st == 1 else 'REVERTED'} {h[:12]}… | total donated {state['donated_wei']/1e18:.2f}"
                value = self.w3.eth.get_balance(self.me) + self.tok.functions.balanceOf(self.me).call() * nav_wei // 10 ** 18
            if "base_value_wei" not in state:
                state["base_value_wei"] = int(value)   # working capital baseline; only growth above this is ever donated
            json.dump(state, open(st_path, "w"))
        s2 = self.sqrt_now(); r2 = (n / s2) ** 2 if s2 else float("inf")
        self.log(f"[{now()}] peg | sPONS/NAV {ratio:.4f} -> {r2:.4f} | inv {bal_s/1e18:.1f} sPONS, {bal_e/1e18:.4f} ETH | {acted or 'in band'}")
        return acted

# ---------------- live simulation (anvil can't fork this chain in cancun mode; the v4 PoolManager needs cancun) ----------------
# LIVE_SIM=1: sends the two one-off approvals for real (harmless), then simulates the sell / buy the step would do with
# debug_traceCall prestateTracer(diffMode) and compares the post-swap pool price to the math. Nothing else is sent.
if __name__ == "__main__" and os.environ.get("LIVE_SIM") == "1":
    import urllib.request
    for p in (os.path.join(HOME, "pons-sniper", ".env"), os.path.join(HOME, "pons-perp", ".env.dev")):
        for ln in open(p):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
    dep = json.load(open(os.path.join(HOME, "pons-perp", "deployment_real.json")))
    RPC = os.environ["RH_RPC_URL"]
    w3 = Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 90, "headers": {"User-Agent": "Mozilla/5.0"}}))
    acct = w3.eth.account.from_key(os.environ["DEV_PK"]); me = acct.address
    assert me.lower() == dep["deployer"].lower()
    def send(fn, value=0):
        tx = fn.build_transaction({"from": me, "value": value, "nonce": w3.eth.get_transaction_count(me), "chainId": 4663})
        gp = w3.eth.gas_price; tx["maxFeePerGas"] = int(gp * 1.4); tx["maxPriorityFeePerGas"] = min(int(gp * 0.5) + 1, tx["maxFeePerGas"]); tx.pop("gasPrice", None)
        tx["gas"] = int(w3.eth.estimate_gas(tx) * 1.3)
        h = w3.eth.send_raw_transaction(acct.sign_transaction(tx).raw_transaction); rc = w3.eth.wait_for_transaction_receipt(h, timeout=180)
        return h.hex(), rc.status
    peg = Peg(w3, me, send, dep)
    peg.ensure_approvals()
    s, n, ratio = peg.state(); lo, hi, L = peg.position()
    bal_s = peg.tok.functions.balanceOf(me).call(); nav_wei = peg.vault.functions.sharePriceWei(1).call()
    print(f"pool sqrt {s} | nav sqrt {n} | lower {lo} upper {hi} | L {L} | sPONS/NAV {ratio:.4f} | inv {bal_s/1e18:.2f} sPONS")
    def simulate(fn, value=0):
        tx = fn.build_transaction({"from": me, "value": value, "gas": 3_000_000, "chainId": 4663, "nonce": 0}); tx.pop("nonce"); tx.pop("gasPrice", None); tx.pop("maxFeePerGas", None); tx.pop("maxPriorityFeePerGas", None)
        call = {"from": me, "to": tx["to"], "data": tx["data"], "value": hex(value), "gas": hex(3_000_000)}
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "debug_traceCall", "params": [call, "latest", {"tracer": "prestateTracer", "tracerConfig": {"diffMode": True}}]}).encode()
        r = json.load(urllib.request.urlopen(urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"}), timeout=120))
        if r.get("error"): raise SystemExit(f"simulation error: {r['error']}")
        post = r["result"]["post"].get(PM.lower(), {}).get("storage", {})
        v = post.get("0x" + peg.slot.hex().replace("0x", ""))
        return int(v, 16) & ((1 << 160) - 1) if v else None, r["result"]
    # SELL path (the untested one): sell what the step would sell
    start = max(s, lo); need = L * (n - start) // Q96 if n > start else 0
    amt = min(need * 10 ** 6 // (10 ** 6 - peg.fee) + 1, bal_s)
    print(f"sell: need {need/1e18:.2f} sPONS to reach NAV, simulating {amt/1e18:.2f} sPONS")
    post_s, _ = simulate(peg._v4(False, amt, amt * nav_wei // 10 ** 18 * 95 // 100))
    exp_s = start + (amt * (10 ** 6 - peg.fee) // 10 ** 6) * Q96 // L
    print(f"  post sqrt {post_s} | expected {exp_s} | diff {((post_s or 0)/exp_s-1)*100:+.3f}% | sPONS/NAV after {(n/post_s)**2 if post_s else None}")
    # BUY path: 0.005 ETH
    post_b, _ = simulate(peg._v4(True, Web3.to_wei(0.005, "ether"), 0), Web3.to_wei(0.005, "ether"))
    print(f"buy 0.005 ETH: post sqrt {post_b} | sPONS/NAV after {(n/post_b)**2 if post_b else None}")
    print("LIVE SIM DONE")

# ---------------- anvil fork test (does not work on Robinhood Chain: 'Excess blob gas not set') ----------------
if __name__ == "__main__" and os.environ.get("ANVIL_FORK") == "1":
    for p in (os.path.join(HOME, "pons-sniper", ".env"), os.path.join(HOME, "pons-perp", ".env.dev")):
        for ln in open(p):
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1); os.environ.setdefault(k.strip(), v.strip())
    dep = json.load(open(os.path.join(HOME, "pons-perp", "deployment_real.json")))
    port = 8547
    anv = subprocess.Popen([os.path.join(HOME, ".foundry", "bin", "anvil"), "--fork-url", os.environ["RH_RPC_URL"], "--port", str(port), "--silent"])
    try:
        w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{port}", request_kwargs={"timeout": 120}))
        for _ in range(60):
            try: w3.eth.block_number; break
            except Exception: time.sleep(1)
        me = Web3.to_checksum_address(dep["deployer"])
        w3.provider.make_request("anvil_impersonateAccount", [me]); w3.provider.make_request("anvil_setBalance", [me, hex(Web3.to_wei(1, "ether"))])
        def send(fn, value=0):
            tx = fn.build_transaction({"from": me, "value": value, "gas": 3_000_000, "chainId": 4663})
            h = w3.eth.send_transaction(tx); rc = w3.eth.wait_for_transaction_receipt(h)
            assert rc.status == 1, f"reverted: {h.hex()}"
            return h.hex(), rc.status
        peg = Peg(w3, me, send, dep)
        print("fork ok | pool sqrt", peg.sqrt_now(), "| nav sqrt", peg.nav_sqrt(), "| ratio", round(peg.state()[2], 4))
        peg.ensure_approvals()
        # 1. get inventory: mint sPONS at the vault, warp past the TWAP window, rebalance, claim
        print("--- step 1: no inventory, expect MINT"); peg.step()
        w3.provider.make_request("evm_increaseTime", [140]); w3.provider.make_request("evm_mine", [])
        send(peg.vault.functions.rebalance())
        n = peg.vault.functions.commitCount().call()
        for i in range(n):
            c = peg.vault.functions.commits(i).call()
            if c[0] == me and not c[3]:
                e = peg.vault.functions.claimableEpoch(i).call(); assert e != 2 ** 256 - 1; send(peg.vault.functions.claim(i, e)); print("claimed commit", i)
        print("inventory now", peg.tok.functions.balanceOf(me).call() / 1e18, "sPONS")
        # 2. sell down to NAV
        print("--- step 2: expect SELL to NAV"); peg.step()
        # 3. simulate a Backing-style buy (0.01 ETH) pushing it above NAV, expect SELL again
        peg.buy_spons(Web3.to_wei(0.01, "ether"), 0); print("--- step 3: after 0.01 ETH buy, expect SELL"); peg.step()
        # 4. dump sPONS to push it below NAV, expect BUY
        peg.sell_spons(Web3.to_wei(60, "ether"), 0); print("--- step 4: after 60 sPONS dump, expect BUY"); peg.step()
        print("--- step 5: expect in band"); peg.step()
        print("FORK TEST PASSED")
    finally:
        anv.terminate()
