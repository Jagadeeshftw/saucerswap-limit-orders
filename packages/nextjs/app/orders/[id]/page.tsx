"use client";

import { useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useAccount } from "wagmi";
import { MirrorLagNotice, StatusBadge } from "~~/components/orders/StatusBits";
import { SweepStatusBanner } from "~~/components/orders/SweepStatusBanner";
import { TxStatus } from "~~/components/orders/TxStatus";
import { SweepStatus, legs, useContractEntityId, useSweepStatus } from "~~/hooks/orders/useMarkets";
import { useCollectionId, useOrder, useOrderTrail } from "~~/hooks/orders/useOrders";
import { vault } from "~~/hooks/orders/useVault";
import { useVaultTx } from "~~/hooks/orders/useVaultTx";
import { durationText } from "~~/utils/orders/budget";
import { GAS_LIMIT } from "~~/utils/orders/gas";
import {
  OrderType,
  comparatorText,
  describeOrder,
  directionOf,
  isOpen,
  peakOf,
  trailingTrigger,
} from "~~/utils/orders/orders";
import type { TrailEntry } from "~~/utils/orders/trail";
import { formatAmount, formatBps, formatHbar, formatPrice, parseAmount, tinybarToWeibar } from "~~/utils/orders/units";

const hashscan = (path: string) => `https://hashscan.io/testnet/${path}`;
const shortAddress = (address: string) => `${address.slice(0, 6)}…${address.slice(-4)}`;
const DATE_FORMAT: Intl.DateTimeFormatOptions = {
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
};

// Timeline markers: filled for what happened to the order, hollow for routine checks.
const MARKER: Record<TrailEntry["tone"], string> = {
  neutral: "border-base-content/40 bg-base-100",
  ok: "border-success bg-success",
  warn: "border-warning bg-warning",
  error: "border-error bg-error",
  primary: "border-primary bg-primary",
};

const Row = ({ label, children }: { label: string; children: React.ReactNode }) => (
  <>
    <dt className="text-base-content/70">{label}</dt>
    <dd className="m-0 min-w-0 text-right [overflow-wrap:anywhere]">{children}</dd>
  </>
);

const OrderDetail = () => {
  const params = useParams<{ id: string }>();
  const id = /^\d+$/.test(params.id) ? BigInt(params.id) : 0n;
  const { address } = useAccount();
  const { order, holder, holderAccountId, isLoading, notFound } = useOrder(id);
  const vaultId = useContractEntityId(vault.address);
  const trail = useOrderTrail(order);
  const collectionId = useCollectionId();
  const tx = useVaultTx();
  const [topUpText, setTopUpText] = useState("5");
  const sweep = useSweepStatus(order?.market.id);

  if (isLoading)
    return <p className="mx-auto w-full max-w-6xl px-4 py-8 text-sm text-base-content/70">Loading order…</p>;
  if (!order || notFound) {
    return (
      <div className="mx-auto grid w-full max-w-6xl gap-3 px-4 py-8">
        <h1 className="m-0 text-2xl font-bold">Order not found</h1>
        <p className="m-0 text-base-content/80">No order #{params.id} exists in this vault.</p>
        <Link className="link link-primary" href="/orders">
          Back to my orders
        </Link>
      </div>
    );
  }

  const { input, output } = legs(order.market, order.side);
  const open = isOpen(order.display);
  const trailing = order.orderType === OrderType.Trailing;
  const peak = peakOf(order);
  const quote = (price: bigint) => `${formatPrice(price)} ${order.market.quote.symbol}`;
  const isHolder = Boolean(holder && address && holder.toLowerCase() === address.toLowerCase());
  const topUp = parseAmount(topUpText, 8);
  const write = (functionName: "cancel" | "executeOrder" | "topUp", value?: bigint) =>
    tx.send({
      address: vault.address as `0x${string}`,
      abi: vault.abi,
      functionName,
      args: [order.id],
      value,
      chainId: vault.chainId,
      gas: GAS_LIMIT[functionName],
    });

  return (
    <div className="mx-auto grid w-full max-w-6xl gap-5 px-4 py-6 sm:py-8">
      <div className="grid gap-1">
        <div className="flex flex-wrap items-center gap-3">
          <h1 className="m-0 text-2xl font-bold">Order #{order.id.toString()}</h1>
          <StatusBadge status={order.display} />
        </div>
        <p className="m-0 text-sm text-base-content/70" data-testid="order-summary-line">
          {describeOrder(
            order.side,
            order.orderType,
            formatAmount(order.amountIn, input.decimals),
            order.market.base.symbol,
            order.market.quote.symbol,
          )}{" "}
          {trailing ? (
            <>
              with a {formatBps(order.typeParam)} trail: sells when {order.market.base.symbol} falls{" "}
              {formatBps(order.typeParam)} below the highest price seen at a check
            </>
          ) : (
            <>
              when {order.market.base.symbol} is {comparatorText(directionOf(order.side, order.orderType))}{" "}
              {formatPrice(order.typeParam)} {order.market.quote.symbol}
            </>
          )}
        </p>
      </div>
      <MirrorLagNotice />
      {open && <SweepStatusBanner marketId={order.market.id} />}

      <div className="grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_380px]">
        <section
          className="grid gap-3 rounded-2xl border border-base-300 bg-base-100 p-4 sm:p-5"
          aria-label="Order trail"
        >
          <h2 className="m-0 text-xs font-semibold tracking-wide text-base-content/70 uppercase">
            Trail from the mirror node
          </h2>
          {trail.error && (
            <p className="m-0 text-sm text-error-content dark:text-error">
              Could not load the trail: {trail.error.message}
            </p>
          )}
          {trail.isLoading && <p className="m-0 text-sm text-base-content/70">Loading events…</p>}
          {trail.data?.length === 0 && (
            <p className="m-0 text-sm text-base-content/70" data-testid="trail-empty">
              The mirror node has no events for this order yet. A new order&apos;s events usually appear within a few
              seconds.
            </p>
          )}
          <ol className="m-0 grid list-none p-0" data-testid="trail">
            {trail.data?.map((entry, i) => (
              <li key={entry.key} className="grid grid-cols-[1.25rem_minmax(0,1fr)_auto] gap-x-3">
                <span className="relative flex justify-center" aria-hidden>
                  {i < trail.data!.length - 1 && <span className="absolute top-4 bottom-0 w-0.5 bg-base-300" />}
                  <span className={`relative mt-1.5 h-3 w-3 rounded-full border-2 ${MARKER[entry.tone]}`} />
                </span>
                <span className="grid gap-0.5 pb-4">
                  <b className="text-sm font-semibold">{entry.title}</b>
                  <span className="text-sm text-base-content/70 [overflow-wrap:anywhere]">{entry.detail}</span>
                </span>
                <span className="pb-4 text-right text-xs text-base-content/70 tabular-nums">
                  {entry.at.toLocaleString("en-GB", {
                    day: "numeric",
                    month: "short",
                    hour: "2-digit",
                    minute: "2-digit",
                  })}
                  <br />
                  <a
                    className="link link-primary font-semibold no-underline"
                    href={hashscan(`transaction/${entry.timestamp}`)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    HashScan ↗
                  </a>
                </span>
              </li>
            ))}
          </ol>
          <p className="m-0 text-xs text-base-content/70">
            Every row is a vault event on the mirror node. Checks are only recorded when the Hedera Schedule Service ran
            them.
          </p>
        </section>

        <aside className="grid gap-4 rounded-2xl border border-base-300 bg-base-100 p-4 sm:p-5">
          <h2 className="m-0 text-xs font-semibold tracking-wide text-base-content/70 uppercase">Summary</h2>
          <dl className="m-0 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm">
            <Row label="Escrowed">
              <span className="font-mono">
                {formatAmount(order.amountIn, input.decimals)} {input.symbol}
              </span>
            </Row>
            <Row label="Receives">{output.symbol}</Row>
            {trailing && (
              <>
                <Row label="Trail">{formatBps(order.typeParam)} below the peak</Row>
                <Row label="Peak">
                  <span className="font-mono" data-testid="trail-peak">
                    {peak > 0n ? quote(peak) : "set at the first check"}
                  </span>
                </Row>
                <Row label="Trigger now">
                  <span className="font-mono" data-testid="trail-trigger">
                    {peak > 0n ? quote(trailingTrigger(peak, order.typeParam)) : "–"}
                  </span>
                </Row>
                {order.price > 0n && (
                  <Row label="Chainlink now">
                    <span className="font-mono">{quote(order.price)}</span>
                  </Row>
                )}
              </>
            )}
            <Row label="Max slippage">{order.slippageBps / 100}%</Row>
            <Row label={open ? "Budget left" : "Budget"}>
              {open ? <span className="font-mono">{formatHbar(order.budget)}</span> : "unused part refunded"}
            </Row>
            {open &&
              order.display !== "budget-empty" &&
              sweep.status === SweepStatus.Scheduled &&
              sweep.nextSweepAt && (
                <Row label="Next market check">
                  <span data-testid="next-check">
                    {sweep.nextSweepAt > Date.now() / 1000
                      ? `in ${durationText(sweep.nextSweepAt - Date.now() / 1000)}`
                      : "due now"}
                  </span>
                </Row>
              )}
            <Row label="Expires">{new Date(order.expiry * 1000).toLocaleString("en-GB", DATE_FORMAT)}</Row>
            {holder && (
              <Row label="Holder">
                <a
                  className="link link-primary"
                  href={hashscan(`account/${holderAccountId ?? holder}`)}
                  target="_blank"
                  rel="noreferrer"
                >
                  <span className="font-mono">{holderAccountId ?? shortAddress(holder)}</span>
                </a>
                {holderAccountId && (
                  <span className="block font-mono text-xs text-base-content/70">{shortAddress(holder)}</span>
                )}
              </Row>
            )}
            {collectionId && (
              <Row label="Order NFT">
                <a
                  className="link link-primary"
                  href={hashscan(`token/${collectionId}/${order.id}`)}
                  target="_blank"
                  rel="noreferrer"
                >
                  <span className="font-mono">
                    {collectionId} #{order.id.toString()}
                  </span>
                </a>
              </Row>
            )}
            <Row label="Vault">
              <a
                className="link link-primary"
                href={hashscan(`contract/${vaultId ?? vault.address}`)}
                target="_blank"
                rel="noreferrer"
              >
                <span className="font-mono">{vaultId ?? shortAddress(vault.address)}</span>
              </a>
            </Row>
          </dl>

          {open && (
            <div className="grid gap-3 border-t border-base-300 pt-4" data-testid="order-actions">
              {order.display === "budget-empty" && (
                <p className="m-0 text-sm text-error-content dark:text-error">
                  Checks are paused because the budget only covers the fill. Top up to resume them.
                </p>
              )}
              <div className="flex items-center gap-2">
                <div className="input input-bordered input-sm flex grow items-center gap-2 rounded-full">
                  <input
                    id="top-up"
                    aria-label="Top-up amount in HBAR"
                    inputMode="decimal"
                    className="grow font-mono"
                    value={topUpText}
                    onChange={e => setTopUpText(e.target.value)}
                  />
                  <span className="text-xs font-semibold text-base-content/70">HBAR</span>
                </div>
                <button
                  type="button"
                  className="btn btn-outline btn-sm rounded-full"
                  disabled={tx.busy || !topUp}
                  onClick={() => write("topUp", tinybarToWeibar(topUp!))}
                >
                  Top up
                </button>
              </div>
              <button
                type="button"
                className="btn btn-outline btn-sm rounded-full"
                disabled={tx.busy}
                onClick={() => write("executeOrder")}
              >
                Check now (you pay the gas)
              </button>
              {isHolder ? (
                <button
                  type="button"
                  className="btn btn-error btn-sm rounded-full"
                  disabled={tx.busy}
                  onClick={() => write("cancel")}
                >
                  Cancel and refund
                </button>
              ) : (
                <p className="m-0 text-xs text-base-content/70">Only the NFT holder can cancel this order.</p>
              )}
              <TxStatus state={tx.state} />
            </div>
          )}
          <a
            className="btn btn-ghost btn-sm rounded-full"
            href={hashscan(`contract/${vaultId ?? vault.address}`)}
            target="_blank"
            rel="noreferrer"
          >
            Open vault on HashScan
          </a>
        </aside>
      </div>
    </div>
  );
};

export default OrderDetail;
