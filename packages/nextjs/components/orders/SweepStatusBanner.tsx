"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { ago } from "~~/components/orders/MarketPanel";
import { TxStatus } from "~~/components/orders/TxStatus";
import { SweepStatus, useSweepStatus } from "~~/hooks/orders/useMarkets";
import { vault } from "~~/hooks/orders/useVault";
import { useVaultTx } from "~~/hooks/orders/useVaultTx";
import { useWallet } from "~~/hooks/orders/useWallet";
import { GAS_LIMIT, maxFee } from "~~/utils/orders/gas";
import { formatAmount } from "~~/utils/orders/units";

const NO_TOKENS: { address: string; entityId: string }[] = [];

/**
 * "Checks stopped": the market has funded orders but no schedule will fire, e.g. because the vault could not pay
 * for one. Anyone can restart the chain; the caller pays for scheduling the next check.
 */
export const SweepStatusBanner = ({ marketId }: { marketId: number }) => {
  const { status, nextSweepAt, refetch } = useSweepStatus(marketId);
  const wallet = useWallet(NO_TOKENS, undefined);
  const tx = useVaultTx();
  const publicClient = usePublicClient({ chainId: vault.chainId });
  const stalled = status === SweepStatus.Stalled;

  const { data: gasPrice } = useQuery({
    queryKey: ["gas-price"],
    queryFn: () => publicClient!.getGasPrice(),
    enabled: stalled && Boolean(publicClient),
  });
  const fee = gasPrice !== undefined ? maxFee(GAS_LIMIT.restartSweep, gasPrice) : undefined;

  if (!stalled) return null;
  const restart = async () => {
    await tx.send({
      address: vault.address as `0x${string}`,
      abi: vault.abi,
      functionName: "restartSweep",
      args: [BigInt(marketId)],
      chainId: vault.chainId,
      gas: GAS_LIMIT.restartSweep,
    });
    await refetch();
  };

  return (
    <div
      className="grid gap-2 rounded-xl border border-error/60 bg-error/10 px-4 py-3"
      role="alert"
      data-testid="checks-stopped"
    >
      <div className="flex items-start gap-3">
        <span className="rounded-full border border-error px-2.5 py-0.5 text-xs font-bold whitespace-nowrap text-error">
          Checks stopped
        </span>
        <p className="m-0 text-sm leading-relaxed">
          Orders in this market are funded, but no check is scheduled: the one due{" "}
          {nextSweepAt ? ago(nextSweepAt) : "earlier"} never ran. That happens when the vault cannot pay for a scheduled
          call, or the network drops it. Anyone can restart checks and pays only the scheduling fee
          {fee !== undefined ? (
            <>
              {" "}
              (at most <b className="font-mono">{formatAmount(fee, 18, 3)} HBAR</b>)
            </>
          ) : null}
          .
        </p>
      </div>
      {wallet.isConnected && !wallet.wrongNetwork ? (
        <button type="button" className="btn btn-error btn-sm w-fit rounded-full" disabled={tx.busy} onClick={restart}>
          Restart checks
        </button>
      ) : (
        <p className="m-0 text-xs text-base-content/70">Connect a wallet on Hedera testnet to restart checks.</p>
      )}
      <TxStatus state={tx.state} />
    </div>
  );
};
