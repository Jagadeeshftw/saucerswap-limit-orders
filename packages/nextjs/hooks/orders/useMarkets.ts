import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { erc20Abi } from "viem";
import { useReadContract, useReadContracts } from "wagmi";
import { REFRESH_MS, vault } from "~~/hooks/orders/useVault";
import { fetchContractId } from "~~/services/mirror";
import { GuardState, Side } from "~~/utils/orders/orders";
import type { TokenMeta } from "~~/utils/orders/trail";
import { entityIdFromAddress, isLongZero } from "~~/utils/orders/units";

export type MarketInfo = {
  id: number;
  base: TokenMeta & { address: string; entityId: string; isHbar: boolean };
  quote: TokenMeta & { address: string; entityId: string; isHbar: boolean };
  poolFee: number;
  poolAddress: string;
  maxSlippageBps: number;
  maxDeviationBps: number;
  maxOracleAge: number;
  twapWindow: number;
  /** Checks run between these bounds; the wait is the time the price needs to reach the nearest trigger. */
  minInterval: number;
  maxInterval: number;
  maxMoveBpsPerHour: number;
  active: boolean;
};

/** Token that goes in and comes out for a side. */
export const legs = (market: MarketInfo, side: Side) =>
  side === Side.SellBase ? { input: market.base, output: market.quote } : { input: market.quote, output: market.base };

/** All listed markets with token symbols, read from the vault and the tokens' ERC-20 facades. */
export const useMarkets = () => {
  const { data: count } = useReadContract({ ...vault, functionName: "marketCount" });
  const ids = useMemo(() => Array.from({ length: Number(count ?? 0) }, (_, i) => BigInt(i + 1)), [count]);

  const { data: markets, isLoading } = useReadContracts({
    contracts: ids.map(id => ({ ...vault, functionName: "getMarket" as const, args: [id] as const })),
    query: { enabled: ids.length > 0 },
  });

  const tokenAddresses = useMemo(() => {
    const set = new Set<string>();
    markets?.forEach(m => {
      if (m.status !== "success") return;
      if (!m.result.baseIsHbar) set.add(m.result.base);
      if (!m.result.quoteIsHbar) set.add(m.result.quote);
    });
    return [...set];
  }, [markets]);

  const { data: symbols } = useReadContracts({
    contracts: tokenAddresses.map(address => ({
      address: address as `0x${string}`,
      abi: erc20Abi,
      functionName: "symbol" as const,
    })),
    query: { enabled: tokenAddresses.length > 0, staleTime: Infinity },
  });

  const list = useMemo<MarketInfo[]>(() => {
    if (!markets) return [];
    const symbolOf = (address: string) => {
      const index = tokenAddresses.indexOf(address);
      const result = symbols?.[index];
      return result?.status === "success" ? (result.result as string) : entityIdFromAddress(address);
    };
    return markets.flatMap((m, i) => {
      if (m.status !== "success") return [];
      const r = m.result;
      return [
        {
          id: i + 1,
          base: {
            address: r.base,
            entityId: entityIdFromAddress(r.base),
            isHbar: r.baseIsHbar,
            decimals: r.baseDecimals,
            symbol: r.baseIsHbar ? "HBAR" : symbolOf(r.base),
          },
          quote: {
            address: r.quote,
            entityId: entityIdFromAddress(r.quote),
            isHbar: r.quoteIsHbar,
            decimals: r.quoteDecimals,
            symbol: r.quoteIsHbar ? "HBAR" : symbolOf(r.quote),
          },
          poolFee: r.poolFee,
          poolAddress: r.pool,
          maxSlippageBps: r.guard.maxSlippageBps,
          maxDeviationBps: r.guard.maxDeviationBps,
          maxOracleAge: r.guard.maxOracleAge,
          twapWindow: r.guard.twapWindow,
          minInterval: r.sweep.minInterval,
          maxInterval: r.sweep.maxInterval,
          maxMoveBpsPerHour: r.sweep.maxMoveBpsPerHour,
          active: r.active,
        },
      ];
    });
  }, [markets, symbols, tokenAddresses]);

  return { markets: list, isLoading: isLoading || count === undefined };
};

/** Entity id of a contract: direct for long-zero addresses, from the mirror node for CREATE/CREATE2 ones. */
export const useContractEntityId = (address: string | undefined) => {
  const { data } = useQuery({
    queryKey: ["contract-id", address],
    queryFn: () => fetchContractId(address as string),
    enabled: Boolean(address) && !isLongZero(address as string),
    staleTime: Infinity,
  });
  if (!address) return undefined;
  return isLongZero(address) ? entityIdFromAddress(address) : data;
};

export type GuardInfo = {
  state: GuardState;
  oraclePrice: bigint;
  poolPrice: bigint;
  deviationBps: bigint;
  oracleUpdatedAt: number;
};

/** The market's guard verdict, refreshed on the polling cadence. */
export const useGuard = (marketId: number | undefined) => {
  const { data, isLoading, error } = useReadContract({
    ...vault,
    functionName: "guardReading",
    args: [BigInt(marketId ?? 0)],
    query: { enabled: marketId !== undefined, refetchInterval: REFRESH_MS },
  });
  const guard: GuardInfo | undefined = data
    ? {
        state: data.state as GuardState,
        oraclePrice: data.oraclePrice,
        poolPrice: data.poolPrice,
        deviationBps: data.deviationBps,
        oracleUpdatedAt: Number(data.oracleUpdatedAt),
      }
    : undefined;
  return { guard, isLoading, error };
};

/**
 * What a new order costs in check budget, straight from the vault's cost views.
 * `sharedCheck` assumes the new order joins the orders already funded in this market.
 */
export const useOrderCosts = (marketId: number | undefined, side: Side) => {
  const id = BigInt(marketId ?? 0);
  const enabled = marketId !== undefined;
  const { data } = useReadContracts({
    contracts: [
      { ...vault, functionName: "checkCost", args: [id] },
      { ...vault, functionName: "fillCost", args: [id, side] },
      { ...vault, functionName: "minBudget", args: [id, side] },
      { ...vault, functionName: "sweeps", args: [id] },
    ],
    query: { enabled, refetchInterval: REFRESH_MS },
  });
  const fundedOrders = data?.[3]?.status === "success" ? Number(data[3].result[3]) : 0;
  // `fillCost` already includes the order's part of a final sweep, so it is the whole reserve.
  const { data: sharedCheck } = useReadContract({
    ...vault,
    functionName: "checkCostShared",
    args: [BigInt(fundedOrders + 1)],
    query: { enabled: enabled && data !== undefined },
  });
  if (!data || data.some(d => d.status !== "success")) return undefined;
  return {
    soloCheck: data[0].result as bigint,
    fill: data[1].result as bigint,
    minBudget: data[2].result as bigint,
    fundedOrders,
    sharedCheck: sharedCheck as bigint | undefined,
  };
};

export enum SweepStatus {
  Idle,
  Scheduled,
  Stalled,
}

/** Whether the market's checks are running, and when the Schedule Service runs the next one. */
export const useSweepStatus = (marketId: number | undefined) => {
  const { data, refetch } = useReadContract({
    ...vault,
    functionName: "sweepStatus",
    args: [BigInt(marketId ?? 0)],
    query: { enabled: marketId !== undefined, refetchInterval: REFRESH_MS },
  });
  return {
    status: data ? (Number(data[0]) as SweepStatus) : undefined,
    nextSweepAt: data ? Number(data[1]) : undefined,
    refetch,
  };
};

/**
 * Seconds until an order would next be checked at today's Chainlink price, for each candidate lifetime.
 * The vault answers with the same rule its sweeps use, so the ticket can size a budget for the whole lifetime.
 */
export const useCheckDelays = (
  marketId: number,
  trigger: number,
  triggerPrice: bigint | null,
  lifetimes: readonly number[],
) => {
  const now = Math.floor(Date.now() / 60_000) * 60;
  const { data } = useReadContracts({
    contracts: lifetimes.map(seconds => ({
      ...vault,
      functionName: "nextCheckDelay" as const,
      args: [BigInt(marketId), trigger, triggerPrice ?? 0n, BigInt(now + seconds)] as const,
    })),
    query: { enabled: Boolean(triggerPrice && triggerPrice > 0n), refetchInterval: REFRESH_MS },
  });
  return lifetimes.map((_, i) => (data?.[i]?.status === "success" ? Number(data[i].result as bigint) : undefined));
};
