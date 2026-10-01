#!/usr/bin/env node
// Print every cost figure the docs quote, read live from OrderVaultLens on Hedera testnet, HBAR first.
//
//   node scripts/cost-figures.mjs          Markdown tables, ready to paste
//   node scripts/cost-figures.mjs --json   the raw numbers
//
// No dependencies: plain JSON-RPC eth_call. Addresses come from packages/nextjs/contracts/deployedContracts.ts,
// so the figures always describe the deployment the app uses. Set HEDERA_RPC_URL to use another relay.
import { readFileSync } from "node:fs";

const RPC = process.env.HEDERA_RPC_URL ?? "https://testnet.hashio.io/api";
const EXCHANGE_RATE = "0x0000000000000000000000000000000000000168";
const TINYBAR = 10n ** 8n;

// Function selectors (keccak of the signature), so the script needs no ABI library.
const SEL = {
  checkCost: "0x11b4a832", // checkCost(uint256)
  checkCostShared: "0x9917f638", // checkCostShared(uint256)
  fillCost: "0x6654a22e", // fillCost(uint256,uint8)
  minBudget: "0x53961d08", // minBudget(uint256,uint8)
  costs: "0x776d62f6", // costs()
  getMarket: "0xeb44fdd3", // getMarket(uint256)
  marketCount: "0xec979082", // marketCount()
  tinycentsToTinybars: "0x2e3cff6a", // tinycentsToTinybars(uint256)
};

const contracts = readFileSync(new URL("../packages/nextjs/contracts/deployedContracts.ts", import.meta.url), "utf8");
const addressOf = name => {
  const match = contracts.match(new RegExp(`\\b${name}: \\{\\s*address: "(0x[0-9a-fA-F]{40})"`));
  if (!match) throw new Error(`${name} is not in deployedContracts.ts; run the deploy first`);
  return match[1];
};
const VAULT = addressOf("OrderVault");
const LENS = addressOf("OrderVaultLens");

const word = value => BigInt(value).toString(16).padStart(64, "0");
let id = 0;
/** eth_call returning the result as 32-byte words. */
const call = async (to, selector, ...args) => {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: ++id,
      method: "eth_call",
      params: [{ to, data: selector + args.map(word).join("") }, "latest"],
    }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${selector} on ${to}: ${body.error.message}`);
  return (body.result.slice(2).match(/.{64}/g) ?? []).map(w => BigInt(`0x${w}`));
};
const one = async (...a) => (await call(...a))[0];

const hbar = (tinybar, digits = 4) => (Number(tinybar) / Number(TINYBAR)).toFixed(digits);

const [rateWord, costs, marketCount] = await Promise.all([
  one(EXCHANGE_RATE, SEL.tinycentsToTinybars, 10n ** 12n), // tinybar per 10^12 tinycents ($100)
  call(VAULT, SEL.costs),
  one(VAULT, SEL.marketCount),
]);
const [scheduleGas, , , , , , , gasPriceTinycents] = costs;
const usdPerHbar = 1e10 / Number(rateWord);
const usd = tinybar => (Number(tinybar) / 1e8) * usdPerHbar;
const date = new Date().toISOString().slice(0, 10);
// The network fee for one scheduleCall: Hedera sets it in USD, so its HBAR figure moves with the rate.
const scheduleFee = (scheduleGas * gasPriceTinycents * rateWord) / 10n ** 12n;

const markets = [];
for (let m = 1n; m <= marketCount; m++) {
  const w = await call(VAULT, SEL.getMarket, m);
  // Market is all static fields: ... baseIsHbar at word 4, then GuardParams at 14..17 and SweepParams at 18..22.
  const sweep = { minInterval: Number(w[18]), maxInterval: Number(w[19]), maxMoveBpsPerHour: Number(w[20]) };
  const [soloCheck, fillHbarSell, fillTokenSell, minHbarSell, minTokenSell] = await Promise.all([
    one(LENS, SEL.checkCost, m),
    one(LENS, SEL.fillCost, m, 0n),
    one(LENS, SEL.fillCost, m, 1n),
    one(LENS, SEL.minBudget, m, 0n),
    one(LENS, SEL.minBudget, m, 1n),
  ]);
  markets.push({ id: Number(m), baseIsHbar: w[4] === 1n, sweep, soloCheck, fillHbarSell, fillTokenSell, minHbarSell, minTokenSell });
}
const shared = Object.fromEntries(
  await Promise.all([1n, 2n, 5n, 20n].map(async n => [Number(n), await one(LENS, SEL.checkCostShared, n)])),
);

const hbarMarket = markets.find(m => m.baseIsHbar) ?? markets[0];
const tokenMarket = markets.find(m => !m.baseIsHbar) ?? markets[0];
const reserveHbarSell = hbarMarket.fillHbarSell;
const reserveTokenSell = tokenMarket.fillHbarSell;
const minHbarSell = hbarMarket.minHbarSell;
const minTokenSell = tokenMarket.minHbarSell;

/** Seconds between checks for a trigger `bps` away, by the vault's rule: as long as the price needs, within bounds. */
const delay = (sweep, bps) =>
  Math.min(sweep.maxInterval, Math.max(sweep.minInterval, Math.floor((bps * 3600) / sweep.maxMoveBpsPerHour)));
const perDay = (seconds, perCheck) => (86_400 / seconds) * (Number(perCheck) / 1e8);
const every = seconds => (seconds >= 3600 ? `${seconds / 3600} h` : `${seconds / 60} min`);
const solo = hbarMarket.soloCheck;
const days = [
  ["HBAR limit 5% away", delay(hbarMarket.sweep, 500)],
  ["HBAR limit 10% away", delay(hbarMarket.sweep, 1000)],
  ["Any trigger 15%+ away, or a long guard hold", hbarMarket.sweep.maxInterval],
  ["DAI stop or trailing stop 50 bps away", delay(tokenMarket.sweep, 50)],
  ["Trigger within 0.2% on HBAR or 0.02% on DAI", hbarMarket.sweep.minInterval],
].map(([what, seconds]) => ({ what, seconds, before: perDay(hbarMarket.sweep.minInterval, solo), after: perDay(seconds, solo) }));

if (process.argv.includes("--json")) {
  const out = {
    date,
    usdPerHbar,
    scheduleFee,
    soloCheck: solo,
    shared,
    reserveHbarSell,
    reserveTokenSell,
    minHbarSell,
    minTokenSell,
    days,
  };
  console.log(JSON.stringify(out, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
  process.exit(0);
}

const cents = usdPerHbar * 100;
console.log(`Live from OrderVaultLens ${LENS} on ${date} (1 HBAR = ${cents.toFixed(2)} ¢ at the testnet rate)\n`);
console.log(
  `Schedule fee: about ${hbar(scheduleFee, 2)} HBAR (≈ $${usd(scheduleFee).toFixed(2)} on ${date}), ` +
    `${Math.round((Number(scheduleFee) / Number(solo)) * 100)}% of a solo check\n`,
);
console.log(`| Cost, read from the lens (${date}, 1 HBAR = ${cents.toFixed(1)} ¢) | HBAR |`);
console.log("| --- | --- |");
console.log(`| One check, the only order in its market | ${hbar(solo)} |`);
console.log(`| One check shared by 2 / 5 / 20 orders | ${hbar(shared[2])} / ${hbar(shared[5])} / ${hbar(shared[20])} |`);
console.log(
  `| Reserve every order keeps for its fill and last check (HBAR sell / token sell) | ${hbar(reserveHbarSell)} / ${hbar(reserveTokenSell)} |`,
);
console.log(`| Minimum budget (HBAR sell / token sell) | ${hbar(minHbarSell)} / ${hbar(minTokenSell)} |`);
console.log("");
console.log("| Situation, one order alone in its market | Before (every 5 min) | After | HBAR a day |");
console.log("| --- | --- | --- | --- |");
for (const d of days) {
  console.log(`| ${d.what} | ${d.before.toFixed(1)} | every ${every(d.seconds)} | ${d.after.toFixed(1)} |`);
}
console.log(
  `\nA single order costs ${days[2].after.toFixed(1)} to ${days[0].after.toFixed(1)} HBAR a day depending on how far ` +
    `the trigger is, instead of ${days[0].before.toFixed(1)} HBAR a day at a check every 5 minutes.`,
);
