"use client";

import { GuardBanner } from "~~/components/orders/StatusBits";
import { type GuardInfo, type MarketInfo, useContractEntityId } from "~~/hooks/orders/useMarkets";
import { formatBps, formatPrice } from "~~/utils/orders/units";

export const ago = (unixSeconds: number, now = Date.now() / 1000) => {
  const seconds = Math.max(0, Math.round(now - unixSeconds));
  if (seconds < 90) return `${seconds} s ago`;
  if (seconds < 90 * 60) return `${Math.round(seconds / 60)} min ago`;
  return `${Math.round(seconds / 3600)} h ago`;
};

const Stat = ({ label, value, note }: { label: string; value: string; note: string }) => (
  <div className="grid gap-1 rounded-xl border border-base-300 bg-base-200 px-4 py-3">
    <span className="text-xs font-medium text-base-content/70">{label}</span>
    <span className="font-mono text-xl font-medium tabular-nums">{value}</span>
    <span className="text-xs text-base-content/70">{note}</span>
  </div>
);

export const MarketPanel = ({ market, guard }: { market: MarketInfo; guard: GuardInfo | undefined }) => {
  const pair = `${market.base.symbol} / ${market.quote.symbol}`;
  const poolId = useContractEntityId(market.poolAddress);
  return (
    <section className="grid gap-4 rounded-2xl border border-base-300 bg-base-100 p-5" aria-label={`${pair} market`}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h1 className="m-0 text-xl font-bold">{pair}</h1>
        <span className="text-sm text-base-content/70">
          SaucerSwap V2 · {market.poolFee / 10_000}% pool{" "}
          {poolId ? (
            <a
              className="link"
              href={`https://hashscan.io/testnet/contract/${poolId}`}
              target="_blank"
              rel="noreferrer"
            >
              {poolId}
            </a>
          ) : (
            "…"
          )}
        </span>
      </div>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
        <Stat
          label={`Chainlink ${market.base.symbol}/${market.quote.symbol}`}
          value={guard && guard.oraclePrice > 0n ? formatPrice(guard.oraclePrice) : "–"}
          note={guard?.oracleUpdatedAt ? `older feed updated ${ago(guard.oracleUpdatedAt)}` : "loading"}
        />
        <Stat
          label={`Pool TWAP (${market.twapWindow / 60} min)`}
          value={guard && guard.poolPrice > 0n ? formatPrice(guard.poolPrice) : "–"}
          note={`in ${market.quote.symbol}`}
        />
        <div className="col-span-2 md:col-span-1">
          <Stat
            label="Deviation"
            value={guard && guard.poolPrice > 0n ? `${guard.deviationBps.toLocaleString("en-US")} bps` : "–"}
            note={`limit ${market.maxDeviationBps} bps (${formatBps(market.maxDeviationBps)})`}
          />
        </div>
      </div>
      {guard && <GuardBanner state={guard.state} />}
      <div className="hidden gap-3 md:grid">
        <h2 className="m-0 text-xs font-semibold tracking-wide text-base-content/70 uppercase">How an order runs</h2>
        {[
          [
            "Escrow",
            "Your tokens and a check budget go into the vault. You receive an order NFT; whoever holds it owns the order.",
          ],
          [
            "Scheduled checks",
            `The vault uses the Hedera Schedule Service to check this market every ${market.sweepInterval / 60} min. No bot is involved.`,
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
    </section>
  );
};
