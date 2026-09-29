import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { type Abi, encodeEventTopics, pad, toHex } from "viem";
import { useReadContract, useReadContracts } from "wagmi";
import { type GuardInfo, type MarketInfo, legs, useGuard, useMarkets } from "~~/hooks/orders/useMarkets";
import { REFRESH_MS, vault } from "~~/hooks/orders/useVault";
import { fetchAccount, fetchHeldSerials, fetchLogs, fetchMirrorLagSeconds } from "~~/services/mirror";
import { ContractStatus, type DisplayStatus, type Order, displayStatus, newestFirst } from "~~/utils/orders/orders";
import { buildTrail } from "~~/utils/orders/trail";
import { entityIdFromAddress } from "~~/utils/orders/units";

type RawOrder = {
  marketId: number;
  side: number;
  trigger: number;
  status: number;
  funded: boolean;
  slippageBps: number;
  createdAt: number;
  expiry: number;
  amountIn: bigint;
  triggerPrice: bigint;
  budget: bigint;
};

const toOrder = (id: bigint, raw: RawOrder): Order => ({ id, ...raw }) as Order;

export type OrderView = Order & { display: DisplayStatus; market: MarketInfo };

const withDisplay = (
  order: Order,
  markets: MarketInfo[],
  guards: Record<number, GuardInfo | undefined>,
): OrderView | undefined => {
  const market = markets.find(m => m.id === order.marketId);
  return market ? { ...order, market, display: displayStatus(order, guards[order.marketId]) } : undefined;
};

/** The order NFT collection's entity id, e.g. 0.0.10779996. */
export const useCollectionId = () => {
  const { data } = useReadContract({ ...vault, functionName: "collection" });
  return data ? entityIdFromAddress(data) : undefined;
};

/** How far back My orders looks for orders the account placed and that have since settled. */
const HISTORY_DAYS = 30;

/** Ids of orders `maker` placed in the last HISTORY_DAYS, from OrderPlaced logs (maker is the third indexed topic). */
const fetchPlacedOrderIds = async (maker: string) => {
  const [topic0] = encodeEventTopics({ abi: vault.abi, eventName: "OrderPlaced" });
  const to = Math.floor(Date.now() / 1000);
  const logs = await fetchLogs(
    vault.address,
    { topic0, topic3: pad(maker as `0x${string}`, { size: 32 }) },
    to - HISTORY_DAYS * 86_400,
    to,
  );
  return logs.map(l => BigInt(l.topics[1]));
};

/**
 * The account's orders, newest first: open orders whose NFT it holds (including ones sent to it), plus orders
 * it placed in the last 30 days. Settled orders have no NFT any more, so the second source keeps their history.
 */
export const useMyOrders = (evmAddress: string | undefined) => {
  const collectionId = useCollectionId();
  const { markets } = useMarkets();
  const guards = useGuardsFor(markets);

  const account = useQuery({
    queryKey: ["mirror-account", evmAddress],
    queryFn: () => fetchAccount(evmAddress as string),
    enabled: Boolean(evmAddress),
  });
  const serials = useQuery({
    queryKey: ["held-orders", account.data?.account, collectionId],
    queryFn: () => fetchHeldSerials(account.data!.account, collectionId as string),
    enabled: Boolean(account.data && collectionId),
    refetchInterval: REFRESH_MS,
  });
  const placed = useQuery({
    queryKey: ["placed-orders", evmAddress],
    queryFn: () => fetchPlacedOrderIds(evmAddress as string),
    enabled: Boolean(evmAddress),
    refetchInterval: REFRESH_MS,
  });
  const ids = useMemo(
    () => [...new Set([...(serials.data ?? []), ...(placed.data ?? [])].map(String))].map(BigInt),
    [serials.data, placed.data],
  );
  const { data: rawOrders, isLoading: ordersLoading } = useReadContracts({
    contracts: ids.map(id => ({ ...vault, functionName: "getOrder" as const, args: [id] as const })),
    query: { enabled: ids.length > 0, refetchInterval: REFRESH_MS },
  });

  const orders = useMemo(() => {
    if (!rawOrders) return [];
    const list = rawOrders.flatMap((r, i) =>
      r.status === "success" ? [withDisplay(toOrder(ids[i], r.result as RawOrder), markets, guards)] : [],
    );
    return newestFirst(list.filter((o): o is OrderView => o !== undefined));
  }, [rawOrders, ids, markets, guards]);

  const hasNoAccount = account.isSuccess && account.data === null;
  return {
    orders,
    isLoading: account.isLoading || serials.isLoading || placed.isLoading || (ids.length > 0 && ordersLoading),
    error: account.error ?? serials.error ?? placed.error,
    hasNoAccount,
  };
};

const useGuardsFor = (markets: MarketInfo[]) => {
  const first = useGuard(markets[0]?.id);
  const second = useGuard(markets[1]?.id);
  return useMemo(() => {
    const out: Record<number, GuardInfo | undefined> = {};
    if (markets[0]) out[markets[0].id] = first.guard;
    if (markets[1]) out[markets[1].id] = second.guard;
    return out;
  }, [markets, first.guard, second.guard]);
};

/** One order with its market, display status and current holder. */
export const useOrder = (id: bigint) => {
  const { markets } = useMarkets();
  const { data, isLoading, error } = useReadContract({
    ...vault,
    functionName: "getOrder",
    args: [id],
    query: { refetchInterval: REFRESH_MS },
  });
  const order = data && data.status !== ContractStatus.None ? toOrder(id, data as RawOrder) : undefined;
  const { guard } = useGuard(order?.marketId);
  const { data: holder } = useReadContract({
    ...vault,
    functionName: "holderOf",
    args: [id],
    query: { enabled: order?.status === ContractStatus.Open, refetchInterval: REFRESH_MS },
  });
  const holderAccount = useQuery({
    queryKey: ["mirror-account", holder],
    queryFn: () => fetchAccount(holder as string),
    enabled: Boolean(holder),
  });
  const view = order ? withDisplay(order, markets, { [order.marketId]: guard }) : undefined;
  return {
    order: view,
    guard,
    holder,
    holderAccountId: holderAccount.data?.account,
    isLoading,
    error,
    notFound: data !== undefined && !order,
  };
};

/**
 * The order's event history from the mirror node, newest first.
 * Raw logs are cached; the readable trail is rebuilt from them whenever market metadata (symbols) arrives.
 */
export const useOrderTrail = (order: OrderView | undefined) => {
  const logs = useQuery({
    queryKey: ["order-logs", order?.id.toString(), order?.status],
    enabled: Boolean(order),
    refetchInterval: REFRESH_MS,
    queryFn: () => {
      const o = order as OrderView;
      const until = Math.min(Math.floor(Date.now() / 1000), o.expiry + 3600);
      return fetchLogs(vault.address, { topic1: pad(toHex(o.id), { size: 32 }) }, o.createdAt - 60, until);
    },
  });
  const data = useMemo(() => {
    if (!order || !logs.data) return undefined;
    const { input, output } = legs(order.market, order.side);
    return buildTrail(vault.abi as Abi, logs.data, input, output);
  }, [order, logs.data]);
  return { data, isLoading: logs.isLoading, error: logs.error };
};

/** How many seconds the mirror node trails consensus; order lists and trails can be this far behind. */
export const useMirrorLag = () =>
  useQuery({ queryKey: ["mirror-lag"], queryFn: fetchMirrorLagSeconds, refetchInterval: 30_000 });
