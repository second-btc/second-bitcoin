import { createPublicClient, createWalletClient, custom, http, formatUnits, getAddress, isAddress, defineChain } from "./vendor/viem.js";
import { CONFIG } from "./config.js";
import { ABI } from "./abi.js";

// ---- config with hardened URL overrides (token/chain pinned except on localhost; rpc/explorer https-only)
const q = new URLSearchParams(location.search);
const cfg = { ...CONFIG };
const isLocal = ["localhost", "127.0.0.1", "0.0.0.0"].includes(location.hostname);
const httpsOnly = (v) => { try { return new URL(v).protocol === "https:" ? v : null; } catch { return null; } };
const localRpc = (v) => { try { const u = new URL(v); return (u.protocol === "https:" || (isLocal && u.protocol === "http:")) ? v : null; } catch { return null; } };
{ const r = localRpc(q.get("rpc")); if (r) cfg.rpc = r; }
{ const e = httpsOnly(q.get("explorer")); if (e) cfg.explorer = e.replace(/\/+$/, ""); }
if (isLocal) { if (q.get("token")) cfg.token = q.get("token"); if (q.get("chain")) cfg.chainId = Number(q.get("chain")); }

const ZERO = "0x0000000000000000000000000000000000000000";
const chain = defineChain({ id: cfg.chainId, name: cfg.chainName, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [cfg.rpc] } }, blockExplorers: { default: { name: "Explorer", url: cfg.explorer } } });
const pub = createPublicClient({ chain, transport: http(cfg.rpc) });

const $ = (id) => document.getElementById(id);
const coins = (u, d = 2) => Number(formatUnits(BigInt(u), 8)).toLocaleString(undefined, { maximumFractionDigits: d });
const short = (h) => h.slice(0, 6) + "…" + h.slice(-4);
const pct = (a, b) => b === 0n ? "0" : (Number((a * 10000n) / b) / 100).toFixed(2);
const fmtDur = (s) => s <= 0 ? "closed" : s < 3600 ? `${Math.round(s / 60)} min` : s < 172800 ? `${(s / 3600).toFixed(1)} h` : `${(s / 86400).toFixed(1)} days`;
function read(fn, args = []) { return pub.readContract({ address: cfg.token, abi: ABI, functionName: fn, args }); }

let wallet = null, account = null;

async function loadStats() {
  const [supply, drawTot, drawClaimed, burned, seed, start, claimWindow] = await Promise.all([
    read("totalSupply"), read("DRAW"), read("drawClaimed"), read("burned"), read("genesisSeed"), read("startTime"), read("CLAIM_WINDOW"),
  ]);
  const sealed = seed !== "0x0000000000000000000000000000000000000000000000000000000000000000";
  $("s-supply").textContent = coins(supply, 0);
  $("s-distributed").textContent = coins(drawClaimed, 0);
  $("s-distributed-sub").textContent = `${pct(drawClaimed, supply)}% of supply`;
  $("s-burned").textContent = coins(burned, 0);
  $("s-status").textContent = sealed ? "Live" : "Awaiting seal";

  if (!sealed) { $("s-epoch").textContent = "Pending"; $("epoch-line").textContent = "The redistribution has not been sealed yet."; return; }
  const now = Math.floor(Date.now() / 1000);
  const closes = Number(start) + Number(claimWindow);
  const remaining = closes - now;
  $("s-epoch").textContent = remaining > 0 ? "Open" : "Closed";
  $("epoch-line").textContent = remaining > 0
    ? `Claims are open. The window closes in ${fmtDur(remaining)}.`
    : `The claim window has closed; unclaimed coins are burned.`;
}

// ---- the redistribution
async function refreshDraw() {
  const box = $("draw-status");
  if (!account) { box.innerHTML = `<span class="muted">Connect your wallet to check your share.</span>`; return; }
  box.innerHTML = `<span class="muted">Checking…</span>`;
  try {
    const seed = await read("genesisSeed");
    if (seed === "0x0000000000000000000000000000000000000000000000000000000000000000") {
      box.innerHTML = `<span class="muted">The redistribution has not been sealed yet — shares are not decided. Check back after the seal.</span>`;
      $("draw-btn").disabled = true; return;
    }
    const [open, winner, claimed] = await Promise.all([read("drawOpen"), read("isDrawWinner", [account]), read("claimedDraw", [account])]);
    if (!winner) { box.innerHTML = `<b>No share.</b> <span class="muted">Your address is eligible but was not selected, or is not in the list.</span>`; $("draw-btn").disabled = true; return; }
    const piece = await read("drawPiece", [account]);
    if (claimed) { box.innerHTML = `<b class="good">Claimed.</b> You received ${coins(piece)} 2BTC.`; $("draw-btn").disabled = true; return; }
    box.innerHTML = `<b class="good">Your share: ${coins(piece)} 2BTC.</b>` + (open ? "" : ` <span class="bad">The claim window is closed.</span>`);
    $("draw-btn").disabled = !open;
  } catch (e) { box.innerHTML = `<span class="bad">${(e.shortMessage || e.message).slice(0, 140)}</span>`; }
}

async function fetchProof(addr) {
  const url = `${cfg.dataBase}proof/${addr.toLowerCase()}.json`;
  const r = await fetch(url);
  if (!r.ok) throw new Error("Proof not found — your address is not in the published eligible set.");
  const j = await r.json();
  if (!Array.isArray(j.proof)) throw new Error("Malformed proof file.");
  return j.proof;
}

async function claimDraw() {
  try {
    $("draw-btn").disabled = true; $("draw-status").innerHTML = `<span class="muted">Fetching proof…</span>`;
    const proof = await fetchProof(account);
    const hash = await wallet.writeContract({ address: cfg.token, abi: ABI, functionName: "claimDraw", args: [proof], account, chain });
    $("draw-status").innerHTML = `<span class="muted">Submitted ${short(hash)} — waiting…</span>`;
    await pub.waitForTransactionReceipt({ hash });
    await refreshDraw(); await loadStats();
  } catch (e) { $("draw-status").innerHTML = `<span class="bad">${(e.shortMessage || e.message).slice(0, 160)}</span>`; $("draw-btn").disabled = false; }
}

// ---- wallet
async function connect() {
  if (!window.ethereum) { alert("No Ethereum wallet found. Install MetaMask."); return; }
  wallet = createWalletClient({ chain, transport: custom(window.ethereum) });
  const [addr] = await wallet.requestAddresses();
  account = getAddress(addr);
  try { await wallet.switchChain({ id: cfg.chainId }); } catch { /* user may add the chain manually */ }
  $("connect").textContent = short(account);
  await refreshDraw();
}

async function main() {
  $("wp-link").href = cfg.whitepaper; $("repo-link").href = cfg.repo;
  $("connect").addEventListener("click", connect);
  $("draw-btn").addEventListener("click", claimDraw);
  if (!cfg.token || cfg.token.toLowerCase() === ZERO) {
    $("prelaunch").style.display = "block";
    $("live").style.display = "none";
    return;
  }
  $("prelaunch").style.display = "none";
  try { await loadStats(); await refreshDraw(); }
  catch (e) { $("epoch-line").innerHTML = `<span class="bad">Could not read the contract: ${(e.shortMessage || e.message).slice(0, 120)}</span>`; }
}
main();
