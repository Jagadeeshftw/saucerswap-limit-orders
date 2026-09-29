"use client";

import { useState } from "react";
import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount } from "wagmi";
import { MirrorLagNotice, StatusBadge } from "~~/components/orders/StatusBits";
import { legs } from "~~/hooks/orders/useMarkets";
import { type OrderView, useCollectionId, useMyOrders } from "~~/hooks/orders/useOrders";
import { comparatorText, describeOrder, isOpen } from "~~/utils/orders/orders";
import { formatAmount, formatHbar, formatPrice } from "~~/utils/orders/units";

type Filter = "all" | "open" | "filled" | "closed";

const matches = (order: OrderView, filter: Filter) => {
  if (filter === "all") return true;
  if (filter === "open") return isOpen(order.display);
  if (filter === "filled") return order.display === "filled";
  return order.display === "cancelled" || order.display === "expired";
};

const describe = (o: OrderView) => {
  const { input } = legs(o.market, o.side);
  return {
    what: describeOrder(
      o.side,
      o.trigger,
      formatAmount(o.amountIn, input.decimals),
      o.market.base.symbol,
      o.market.quote.symbol,
    ),
    trigger: `${o.market.base.symbol} ${comparatorText(o.trigger)} ${formatPrice(o.triggerPrice)} ${o.market.quote.symbol}`,
    budget: isOpen(o.display) ? `${formatHbar(o.budget)} budget` : "settled",
  };
};

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
        <p className="m-0 max-w-prose text-base-content/80">
          Connect a wallet to see the orders it holds. Orders are NFTs, so this list follows whoever holds them.
        </p>
        <ConnectButton.Custom>
          {({ openConnectModal }) => (
            <button type="button" className="btn btn-primary w-fit rounded-full" onClick={openConnectModal}>
              Connect wallet
            </button>
          )}
        </ConnectButton.Custom>
      </div>
    );
  }

  return (
    <div className="mx-auto grid w-full max-w-6xl gap-4 px-4 py-6 sm:py-8">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h1 className="m-0 text-2xl font-bold">My orders</h1>
        <span className="text-sm text-base-content/70" data-testid="orders-summary">
          {counts.all} {counts.all === 1 ? "order" : "orders"} · {counts.open} open
        </span>
      </div>
      <MirrorLagNotice />

      <div className="flex flex-wrap gap-1.5" role="tablist" aria-label="Filter orders">
        {(["all", "open", "filled", "closed"] as Filter[]).map(f => (
          <button
            key={f}
            type="button"
            role="tab"
            aria-selected={filter === f}
            data-testid={`filter-${f}`}
            onClick={() => setFilter(f)}
            className={`rounded-full border px-3 py-1 text-sm font-semibold ${
              filter === f ? "border-primary bg-primary/10 text-primary" : "border-base-300 text-base-content/70"
            }`}
          >
            {f[0].toUpperCase() + f.slice(1)} {counts[f]}
          </button>
        ))}
      </div>

      {error && (
        <p className="m-0 rounded-lg bg-error/10 px-3 py-2 text-sm text-error" role="alert">
          Could not load orders from the mirror node ({error.message}). They will reload automatically.
        </p>
      )}

      {isLoading ? (
        <p className="m-0 text-sm text-base-content/70">Loading orders from the mirror node…</p>
      ) : shown.length === 0 ? (
        <div
          className="grid justify-items-start gap-3 rounded-2xl border border-dashed border-base-300 p-6"
          data-testid="orders-empty"
        >
          <p className="m-0 font-semibold">{orders.length === 0 ? "No orders yet" : "No orders in this view"}</p>
          <p className="m-0 max-w-prose text-sm text-base-content/80">
            {hasNoAccount
              ? "This address has no Hedera testnet account yet. Fund it from the Hedera Portal faucet, then place an order."
              : orders.length === 0
                ? "Orders you place, or order NFTs sent to you, show up here."
                : "Try another filter."}
          </p>
          {orders.length === 0 && (
            <Link href="/" className="btn btn-primary btn-sm rounded-full">
              Place an order
            </Link>
          )}
        </div>
      ) : (
        <>
          <div className="hidden overflow-x-auto rounded-2xl border border-base-300 bg-base-100 md:block">
            <table className="table">
              <thead>
                <tr>
                  <th>Order</th>
                  <th>Trigger</th>
                  <th>Status</th>
                  <th>Budget</th>
                  <th className="text-right" />
                </tr>
              </thead>
              <tbody>
                {shown.map(o => {
                  const d = describe(o);
                  return (
                    <tr key={o.id.toString()} data-testid="order-row">
                      <td>
                        <b className="tabular-nums">#{o.id.toString()}</b> · {d.what}
                      </td>
                      <td className="font-mono text-sm">{d.trigger}</td>
                      <td>
                        <StatusBadge status={o.display} />
                      </td>
                      <td className="text-sm text-base-content/70">{d.budget}</td>
                      <td className="text-right">
                        <Link className="link link-primary font-semibold" href={`/orders/${o.id}`}>
                          View
                        </Link>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <div className="grid gap-3 md:hidden">
            {shown.map(o => {
              const d = describe(o);
              return (
                <Link
                  key={o.id.toString()}
                  href={`/orders/${o.id}`}
                  className="grid gap-2 rounded-2xl border border-base-300 bg-base-100 p-4"
                  data-testid="order-card"
                >
                  <span className="flex items-center justify-between gap-2">
                    <b className="tabular-nums">
                      #{o.id.toString()} · {d.what}
                    </b>
                    <StatusBadge status={o.display} />
                  </span>
                  <span className="flex justify-between gap-2 text-sm">
                    <span className="text-base-content/70">Trigger</span>
                    <span className="font-mono">{d.trigger}</span>
                  </span>
                  <span className="flex justify-between gap-2 text-sm">
                    <span className="text-base-content/70">Budget</span>
                    <span>{d.budget}</span>
                  </span>
                </Link>
              );
            })}
          </div>
          {collectionId && (
            <p className="m-0 text-sm text-base-content/70">
              Orders are NFTs in collection {collectionId}. Transfer the NFT and the order, its refund and its proceeds
              move with it.
            </p>
          )}
        </>
      )}
    </div>
  );
};

export default OrdersPage;
