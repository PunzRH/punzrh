// Cloudflare Pages Function: GET /metrics
// Serves the readout punzrh.com's app.js expects:
//   { tokenAddress, marketPriceEth, shortNavEth, backingPerPunzEth, updatedAt }
// Reads straight from Robinhood Chain — no server, no database. Configure via Pages env vars:
//   RPC_URL      Robinhood Chain JSON-RPC (put a private Chainstack URL here as a SECRET; public: https://rpc.mainnet.chain.robinhood.com)
//   TOKEN        coin address                     PERP      PonsPerpPool address
//   BACKING      Backing contract address         SLOT0_KEY storage key of the ETH/coin pool's slot0 (keccak(poolId ‖ 6)), from launch_real.py
// All values come from deployment_real.json's "site" block; launch_real.py prints them.

const PM = "0x8366a39cc670b4001a1121b8f6a443a643e40951"; // Uniswap v4 PoolManager
const Q96 = 2n ** 96n;

async function rpc(url, method, params) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || "rpc error");
  return j.result;
}
const call = (url, to, data) => rpc(url, "eth_call", [{ to, data }, "latest"]);
const hex = (n) => "0x" + n.toString(16);

export async function onRequestGet({ env }) {
  const { RPC_URL, TOKEN, PERP, BACKING, SLOT0_KEY } = env;
  const headers = {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "cache-control": "public, max-age=20, s-maxage=20",
  };
  if (!(RPC_URL && TOKEN && PERP && BACKING && SLOT0_KEY)) {
    return new Response(JSON.stringify({ error: "metrics not configured" }), { status: 503, headers });
  }
  try {
    const [navHex, floorHex, slot0Hex, navLHex, twapHex, longHex, shortHex, epochHex, ownerHex,
           sbHex, swHex, cmHex, supHex] = await Promise.all([
      call(RPC_URL, PERP, "0x6b6dfd3c" + "1".padStart(64, "0")),      // sharePriceWei(uint8 side=1 SHORT)
      call(RPC_URL, BACKING, "0xd438686f"),                              // floorWeiPerToken()
      call(RPC_URL, PM, "0x1e2eaeaf" + SLOT0_KEY.replace(/^0x/, "")),  // extsload(bytes32)
      call(RPC_URL, PERP, "0x6b6dfd3c" + "0".padStart(64, "0")),      // sharePriceWei(0 = LONG)
      call(RPC_URL, PERP, "0x829117a1"),                                 // twapPriceX96()  (PONS price the vault uses)
      call(RPC_URL, PERP, "0xf1e2dbbf"),                                 // longBal()
      call(RPC_URL, PERP, "0xa3af9574"),                                 // shortBal()
      call(RPC_URL, PERP, "0x829965cc"),                                 // epochCount()
      call(RPC_URL, PERP, "0x8da5cb5b"),                                 // owner()
      call(RPC_URL, BACKING, "0x48f84dc5"),                              // sponsBacking()
      call(RPC_URL, BACKING, "0x983c6ebb"),                              // totalEthSwapped()  (instant path)
      call(RPC_URL, BACKING, "0x9e5bc546"),                              // totalEthCommitted() (vault path)
      call(RPC_URL, TOKEN, "0x18160ddd"),                                // totalSupply()
    ]);
    const nav = BigInt(navHex);                       // wei per 1e18 sPONS
    const floor = BigInt(floorHex);                   // wei per 1e18 coin
    const sqrtP = BigInt(slot0Hex) & ((1n << 160n) - 1n); // currency0 = ETH, currency1 = coin -> coin per ETH
    // coin-per-ETH = (sqrtP/2^96)^2 ; ETH-per-coin = 1 / that. Do it in floating point at the end (display only).
    const sqrt = Number(sqrtP) / Number(Q96);
    const coinPerEth = sqrt * sqrt;
    const f = (h) => Number(BigInt(h)) / 1e18;
    const supply = f(supHex);
    const body = {
      tokenAddress: TOKEN,
      marketPriceEth: coinPerEth > 0 ? 1 / coinPerEth : null,
      shortNavEth: Number(nav) / 1e18,
      backingPerPunzEth: Number(floor) / 1e18,
      // --- live short index (extra fields; safe for the existing app.js to ignore) ---
      ponsPriceEth: Number(BigInt(twapHex)) / Number(Q96),   // PONS in ETH, the TWAP the vault rebalances on
      longNavEth: f(navLHex),                                 // lPONS NAV
      vaultShortEth: f(shortHex),                             // ETH on the short side of the vault
      vaultLongEth: f(longHex),                               // ETH on the long side
      rebalances: Number(BigInt(epochHex)),
      vaultOwner: "0x" + ownerHex.slice(-40),                 // 0x000…000 = renounced
      sponsBacking: f(sbHex),                                 // sPONS held by Backing (only leaves via redeem)
      feesToShortEth: f(swHex) + f(cmHex),                    // total trade-fee ETH converted into the short
      feesInstantEth: f(swHex),
      feesVaultEth: f(cmHex),
      totalSupply: supply,
      burned: 1e9 - supply,
      floorValueEth: (Number(floor) / 1e18) * supply,        // what the whole supply redeems for
      updatedAt: Math.floor(Date.now() / 1000),
    };
    return new Response(JSON.stringify(body), { headers });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e.message || e) }), { status: 502, headers });
  }
}
