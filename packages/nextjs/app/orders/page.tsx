"use client";

import { useState } from "react";
import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount } from "wagmi";
import { MirrorLagNotice, StatusBadge } from "~~/components/orders/StatusBits";
import { legs } from "~~/hooks/orders/useMarkets";
import { type OrderView, useCollectionId, useMyOrders } from "~~/hooks/orders/useOrders";
import { isOpen, sideTypeLabel, triggerSummary } from "~~/utils/orders/orders";
import { formatAmount, formatHbar } from "~~/utils/orders/units";

type Filter = "all" | "open" | "filled" | "closed";

const matches = (order: OrderView, filter: Filter) => {
  if (filter === "all") return true;
  if (filter === "open") return isOpen(order.display);
  if (filter === "filled") return order.display === "filled";
  return order.display === "cancelled" || order.display === "expired";
};

const describe = (o: OrderView) => {
  const { input } = legs(o.market, o.side);
  const trigger = triggerSummary(o);
  return {
    pair: `${o.market.base.symbol} / ${o.market.quote.symbol}`,
    kind: sideTypeLabel(o.side, o.orderType),
    trigger: trigger.main,
    triggerSub: trigger.sub,
    unit: o.market.quote.symbol,
    size: `${formatAmount(o.amountIn, input.decimals)} ${input.symbol}`,
    budget: isOpen(o.display) ? formatHbar(o.budget, 2) : "settled",
  };
};

/** Market and side · type: the side is a plain word, not a colour, so it never reads as profit or loss. */
const Kind = ({ kind }: { kind: string }) => {
  const [side, type] = kind.split(" · ");
  return (
    <span className="text-xs text-base-content/70">
      <b className="font-semibold text-base-content/90">{side}</b> · {type}
    </span>
  );
};

const COLUMNS = "md:grid-cols-[4rem_minmax(0,1.4fr)_minmax(0,1.3fr)_minmax(0,1fr)_minmax(0,0.9fr)_7.5rem]";

const OrdersPage = () => {
  const { address, isConnected } = useAccount();
  const collectionId = useCollectionId();
  const { orders, isLoading, error, hasNoAccount } = useMyOrders(address);
  const [filter, setFilter] = useState<Filter>("all");

  const counts: Record<Filter, number> = {
    all: orders.length,
    open: orders.filter(o => matches(o, "open")).length,
    filled: orders.filter(o => matches(o, "filled")).length,
    closed: orders.filter(o => matches(o, "closed")).length,
  };
  const shown = orders.filter(o => matches(o, filter));

  if (!isConnected) {
    return (
      <div className="mx-auto grid w-full max-w-6xl gap-4 px-4 py-8">
        <h1 className="m-0 text-2xl font-bold">My orders</h1>
        <div className="grid justify-items-center gap-3 rounded-2xl border border-base-300 bg-base-100 px-6 py-10 text-center">
          <span
            className="grid h-11 w-11 place-items-center rounded-2xl border border-base-300 bg-base-200 text-lg"
            aria-hidden
          >
            ◎
          </span>
          <p className="m-0 font-semibold">Connect a wallet to see the orders it holds.</p>
          <p className="m-0 max-w-sm text-sm text-base-content/70">
            Orders are NFTs, so this list follows whoever holds them.
          </p>
          <ConnectButton.Custom>
            {({ openConnectModal }) => (
              <button type="button" className="btn btn-primary btn-sm rounded-full px-5" onClick={openConnectModal}>
                Connect wallet
              </button>
            )}
          </ConnectButton.Custom>
        </div>
      </div>
    );
  }

  return (
    <div className="mx-auto grid w-full max-w-6xl gap-4 px-4 py-6 sm:py-8">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h1 className="m-0 text-2xl font-bold">My orders</h1>
        {!isLoading && (
          <span className="text-sm text-base-content/70" data-testid="orders-summary">
            {counts.all} {counts.all === 1 ? "order" : "orders"} · {counts.open} open
          </span>
        )}
      </div>
      <MirrorLagNotice />

      <div
        className="flex w-fit max-w-full flex-wrap gap-1 rounded-full border border-base-300 bg-base-100 p-1"
        role="tablist"
        aria-label="Filter orders"
      >
        {(["all", "open", "filled", "closed"] as Filter[]).map(f => (
          <button
            key={f}
            type="button"
            role="tab"
            aria-selected={filter === f}
            data-testid={`filter-${f}`}
            onClick={() => setFilter(f)}
            className={`rounded-full px-3 py-1 text-sm font-semibold ${
              filter === f ? "bg-primary/10 text-primary" : "text-base-content/70"
            }`}
          >
            {f[0].toUpperCase() + f.slice(1)} <span className="tabular-nums">{counts[f]}</span>
          </button>
        ))}
      </div>

      {error && (
        <p className="m-0 rounded-lg bg-error/10 px-3 py-2 text-sm text-error-content dark:text-error" role="alert">
          Could not load orders from the mirror node ({error.message}). They will reload automatically.
        </p>
      )}

      {isLoading ? (
        <p className="m-0 text-sm text-base-content/70">Loading orders from the mirror node…</p>
      ) : shown.length === 0 ? (
        <div
          className="grid justify-items-center gap-3 rounded-2xl border border-base-300 bg-base-100 px-6 py-10 text-center"
          data-testid="orders-empty"
        >
          <span
            className="grid h-11 w-11 place-items-center rounded-2xl border border-base-300 bg-base-200 text-lg"
            aria-hidden
          >
            ◎
          </span>
          <p className="m-0 font-semibold">{orders.length === 0 ? "No orders yet" : "No orders in this view"}</p>
          <p className="m-0 max-w-sm text-sm text-base-content/70">
            {hasNoAccount
              ? "This address has no Hedera testnet account yet. Fund it from the Hedera Portal faucet, then place an order."
              : orders.length === 0
                ? "Place a limit, stop or trailing order on the Trade page. It becomes an NFT you hold, and the network watches it for you. Order NFTs sent to you show up here too."
                : "Try another filter."}
          </p>
          {orders.length === 0 && (
            <Link href="/" className="btn btn-primary btn-sm rounded-full px-5">
              Go to Trade
            </Link>
          )}
        </div>
      ) : (
        <>
          <div className="grid gap-2" role="table" aria-label="Orders">
            <div
              className={`hidden gap-3 px-4 text-[11px] font-semibold tracking-wider text-base-content/70 uppercase md:grid ${COLUMNS}`}
              role="row"
            >
              <span role="columnheader">Order</span>
              <span role="columnheader">Market / side</span>
              <span role="columnheader">Trigger</span>
              <span role="columnheader">Size</span>
              <span role="columnheader">Budget</span>
              <span role="columnheader" className="text-right">
                Status
              </span>
            </div>
            {shown.map(o => {
              const d = describe(o);
              return (
                <div key={o.id.toString()} role="row">
                  {/* Desktop: one aligned row per order. */}
                  <Link
                    href={`/orders/${o.id}`}
                    className={`hidden items-center gap-3 rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-sm hover:border-primary/40 md:grid ${COLUMNS}`}
                    data-testid="order-row"
                  >
                    <b className="font-mono tabular-nums" role="cell">
                      #{o.id.toString()}
                    </b>
                    <span className="grid min-w-0" role="cell">
                      <span className="font-semibold">{d.pair}</span>
                      <Kind kind={d.kind} />
                    </span>
                    <span className="grid min-w-0" role="cell">
                      <span className="font-mono tabular-nums">
                        {d.trigger} {!d.triggerSub && <span className="text-xs text-base-content/60">{d.unit}</span>}
                      </span>
                      {d.triggerSub && (
                        <span className="font-mono text-xs text-base-content/70 tabular-nums">
                          {d.triggerSub} {d.unit}
                        </span>
                      )}
                    </span>
                    <span className="font-mono tabular-nums" role="cell">
                      {d.size}
                    </span>
                    <span className="font-mono text-xs text-base-content/70 tabular-nums" role="cell">
                      {d.budget}
                    </span>
                    <span className="justify-self-end" role="cell">
                      <StatusBadge status={o.display} />
                    </span>
                  </Link>
                  {/* 390: a card with the same facts, status beside the title. */}
                  <Link
                    href={`/orders/${o.id}`}
                    className="grid gap-2 rounded-xl border border-base-300 bg-base-100 p-4 md:hidden"
                    data-testid="order-card"
                  >
                    <span className="flex items-start justify-between gap-2">
                      <span className="grid min-w-0">
                        <b className="text-sm">
                          <span className="font-mono tabular-nums">#{o.id.toString()}</span> · {d.pair}
                        </b>
                        <Kind kind={d.kind} />
                      </span>
                      <StatusBadge status={o.display} />
                    </span>
                    <span className="grid grid-cols-3 gap-2 text-xs">
                      <span className="grid min-w-0">
                        <span className="text-base-content/70">Trigger</span>
                        <span className="font-mono text-sm tabular-nums">{d.trigger}</span>
                        {d.triggerSub && (
                          <span className="font-mono text-base-content/70 tabular-nums">{d.triggerSub}</span>
                        )}
                      </span>
                      <span className="grid min-w-0">
                        <span className="text-base-content/70">Size</span>
                        <span className="font-mono text-sm tabular-nums">{d.size}</span>
                      </span>
                      <span className="grid min-w-0 text-right">
                        <span className="text-base-content/70">Budget</span>
                        <span className="font-mono text-sm tabular-nums">{d.budget}</span>
                      </span>
                    </span>
                  </Link>
                </div>
              );
            })}
          </div>
          {collectionId && (
            <p className="m-0 text-sm text-base-content/70">
              Orders are NFTs in collection <span className="font-mono">{collectionId}</span>. Transfer the NFT and the
              order, its refund and its proceeds move with it.
            </p>
          )}
        </>
      )}
    </div>
  );
};

export default OrdersPage;
