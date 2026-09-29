"use client";

import { Suspense } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { MarketPanel } from "~~/components/orders/MarketPanel";
import { OrderTicket } from "~~/components/orders/OrderTicket";
import { useGuard, useMarkets } from "~~/hooks/orders/useMarkets";

const TradePage = () => {
  const { markets, isLoading } = useMarkets();
  const params = useSearchParams();
  const selectedId = Number(params.get("market") ?? markets[0]?.id ?? 1);
  const market = markets.find(m => m.id === selectedId) ?? markets[0];
  const { guard } = useGuard(market?.id);

  if (isLoading || !market) {
    return (
      <p className="mx-auto w-full max-w-6xl px-4 py-8 text-sm text-base-content/70">Loading markets from the vault…</p>
    );
  }

  return (
    <div className="mx-auto grid w-full max-w-6xl gap-5 px-4 py-6 sm:py-8">
      <nav className="flex flex-wrap gap-1.5" aria-label="Markets">
        {markets.map(m => (
          <Link
            key={m.id}
            href={`/?market=${m.id}`}
            aria-current={m.id === market.id ? "page" : undefined}
            data-testid={`market-${m.id}`}
            className={`rounded-full border px-3 py-1 text-sm font-semibold ${
              m.id === market.id ? "border-primary bg-primary/10 text-primary" : "border-base-300 text-base-content/70"
            }`}
          >
            {m.base.symbol} / {m.quote.symbol}
          </Link>
        ))}
      </nav>
      <div className="grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_440px]">
        <MarketPanel market={market} guard={guard} />
        <OrderTicket key={market.id} market={market} guard={guard} />
      </div>
    </div>
  );
};

const Page = () => (
  <Suspense>
    <TradePage />
  </Suspense>
);

export default Page;
