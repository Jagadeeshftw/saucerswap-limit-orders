import { useCallback, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { TransactionReceipt } from "viem";
import { usePublicClient, useWriteContract } from "wagmi";
import { explainError } from "~~/utils/orders/errors";

export type TxState =
  | { status: "idle" }
  | { status: "signing" }
  | { status: "confirming"; hash: `0x${string}` }
  | { status: "success"; hash: `0x${string}` }
  | { status: "failed"; message: string; hash?: `0x${string}` };

type WagmiWriteArgs = Parameters<ReturnType<typeof useWriteContract>["writeContractAsync"]>[0];
/** wagmi's parameters with `value` widened: the inferred defaults would only allow it on payable ABIs. */
type WriteArgs = Omit<WagmiWriteArgs, "value"> & { value?: bigint };

/**
 * One contract write with the states the UI shows inline: waiting for the wallet, waiting for consensus,
 * done, or failed with a readable reason. Reverted receipts count as failures.
 */
export const useVaultTx = () => {
  const [state, setState] = useState<TxState>({ status: "idle" });
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();
  const queryClient = useQueryClient();

  /** Resolves to the receipt of a successful transaction, or undefined when it was rejected or failed. */
  const send = useCallback(
    async (args: WriteArgs): Promise<TransactionReceipt | undefined> => {
      setState({ status: "signing" });
      let hash: `0x${string}` | undefined;
      try {
        hash = await writeContractAsync(args as WagmiWriteArgs);
        setState({ status: "confirming", hash });
        const receipt = await publicClient!.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") {
          setState({
            status: "failed",
            hash,
            message: "The transaction reverted on-chain. Open it on HashScan for the reason.",
          });
          return undefined;
        }
        setState({ status: "success", hash });
        await queryClient.invalidateQueries();
        return receipt;
      } catch (error) {
        setState({ status: "failed", hash, message: explainError(error) });
        return undefined;
      }
    },
    [writeContractAsync, publicClient, queryClient],
  );

  const reset = useCallback(() => setState({ status: "idle" }), []);
  return { state, send, reset, busy: state.status === "signing" || state.status === "confirming" };
};
