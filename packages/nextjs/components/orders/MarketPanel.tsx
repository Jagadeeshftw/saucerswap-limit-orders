"use client";

import { GuardBanner } from "~~/components/orders/StatusBits";
import { SweepStatusBanner } from "~~/components/orders/SweepStatusBanner";
import { type GuardInfo, type MarketInfo, useContractEntityId } from "~~/hooks/orders/useMarkets";
import { durationText } from "~~/utils/orders/budget";
import { GuardState } from "~~/utils/orders/orders";
import { formatBps, formatPrice } from "~~/utils/orders/units";

export const ago = (unixSeconds: number, now = Date.now() / 1000) => {
  const seconds = Math.max(0, Math.round(now - unixSeconds));
  if (seconds < 90) return `${seconds} s ago`;
  if (seconds < 90 * 60) return `${Math.round(seconds / 60)} min ago`;
  return `${Math.round(seconds / 3600)} h ago`;
};

/** One price, paired with the other so the gap reads at a glance; tabular figures, unit always shown. */
const PriceTile = ({
  label,
  value,
  unit,
  note,
  testId,
}: {
  label: string;
  value: string;
  unit: string;
  note: string;
  testId: string;
}) => (
  <div
    className="grid min-w-0 gap-0.5 rounded-xl border border-base-300 bg-base-200 px-3.5 py-2.5"
    data-testid={testId}
  >
    <span className="text-[11px] font-semibold tracking-wider text-base-content/70 uppercase">{label}</span>
    <span className="font-mono text-lg font-semibold tabular-nums sm:text-xl">
      {value} <span className="text-xs font-semibold text-base-content/60">{unit}</span>
    </span>
    <span className="text-xs text-base-content/70">{note}</span>
  </div>
);

/** The live reading behind the guard verdict: how far apart the two prices are, and how fresh Chainlink is. */
const guardFacts = (market: MarketInfo, guard: GuardInfo) => {
  const feed = guard.oracleUpdatedAt ? ` · feed ${ago(guard.oracleUpdatedAt).replace(" ago", " old")}` : "";
  if (guard.poolPrice === 0n) return `No pool TWAP to compare${feed}`;
  const bps = guard.deviationBps.toLocaleString("en-US");
  return guard.deviationBps <= BigInt(market.maxDeviationBps)
    ? `Pool within ${bps} bps of Chainlink, limit ${market.maxDeviationBps} bps${feed}`
    : `Pool ${bps} bps from Chainlink, limit ${market.maxDeviationBps} bps (${formatBps(market.maxDeviationBps)})${feed}`;
};

export const MarketPanel = ({ market, guard }: { market: MarketInfo; guard: GuardInfo | undefined }) => {
  const pair = `${market.base.symbol} / ${market.quote.symbol}`;
  const poolId = useContractEntityId(market.poolAddress);
  return (
    <section
      className="grid gap-4 rounded-2xl border border-base-300 bg-base-100 p-4 sm:p-5"
      aria-label={`${pair} market`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="m-0 flex items-center gap-2.5 text-xl font-bold">
          <span className="h-6 w-6 rounded-full bg-linear-to-br from-primary to-accent" aria-hidden />
          {pair}
        </h1>
        <a
          className="rounded-full border border-base-300 px-2.5 py-0.5 text-xs font-semibold text-base-content/70 hover:border-primary/50"
          href={poolId ? `https://hashscan.io/testnet/contract/${poolId}` : undefined}
          target="_blank"
          rel="noreferrer"
          title="The SaucerSwap V2 pool this market swaps in"
        >
          SaucerSwap V2 · {market.poolFee / 10_000}% pool{poolId ? ` · ${poolId}` : ""}
        </a>
      </div>
      <div className="grid grid-cols-2 gap-2 sm:gap-3">
        <PriceTile
          label="Pool TWAP"
          testId="price-pool"
          value={guard && guard.poolPrice > 0n ? formatPrice(guard.poolPrice) : "–"}
          unit={market.quote.symbol}
          note={`${market.twapWindow / 60} min time-weighted`}
        />
        <PriceTile
          label="Chainlink"
          testId="price-chainlink"
          value={guard && guard.oraclePrice > 0n ? formatPrice(guard.oraclePrice) : "–"}
          unit={market.quote.symbol}
          note={
            !guard?.oracleUpdatedAt
              ? "loading"
              : guard.state === GuardState.OracleStale
                ? `updated ${ago(guard.oracleUpdatedAt)}, max age ${durationText(market.maxOracleAge)}`
                : `updated ${ago(guard.oracleUpdatedAt)}`
          }
        />
      </div>
      {guard && <GuardBanner state={guard.state} facts={guardFacts(market, guard)} />}
      <SweepStatusBanner marketId={market.id} />
      <div className="hidden gap-3 md:grid">
        <h2 className="m-0 text-xs font-semibold tracking-wide text-base-content/70 uppercase">How an order runs</h2>
        <div className="grid gap-3">
          {[
            [
              "Escrow",
              "Your tokens and a check budget go into the vault. You receive an order NFT; whoever holds it owns the order.",
            ],
            [
              "Scheduled checks",
              `The vault uses the Hedera Schedule Service to check this market. Each check waits about as long as the price needs to reach the nearest trigger (at up to ${formatBps(market.maxMoveBpsPerHour)} an hour), between ${durationText(market.minInterval)} and ${durationText(market.maxInterval)}. No bot is involved.`,
            ],
            [
              "Fill or refund",
              "When the trigger is met and the guard is open, it swaps on SaucerSwap. Proceeds and unused budget go to the NFT holder.",
            ],
          ].map(([title, body], i) => (
            <div key={title} className="grid grid-cols-[1.5rem_1fr] gap-3 text-sm leading-relaxed">
              <span className="grid h-6 w-6 place-items-center rounded-full bg-primary/10 text-xs font-bold text-primary">
                {i + 1}
              </span>
              <span>
                <b className="font-semibold">{title}.</b> {body}
              </span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
};
