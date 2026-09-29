"use client";

import type { TxState } from "~~/hooks/orders/useVaultTx";

export const hashscanTx = (hash: string) => `https://hashscan.io/testnet/transaction/${hash}`;

/** Inline line under an action: what the transaction is waiting for, or why it failed. */
export const TxStatus = ({ state, successText }: { state: TxState; successText?: string }) => {
  switch (state.status) {
    case "idle":
      return null;
    case "signing":
      return (
        <p className="m-0 text-sm text-base-content/80" role="status" data-testid="tx-status">
          Confirm the transaction in your wallet.
        </p>
      );
    case "confirming":
      return (
        <p className="m-0 text-sm text-base-content/80" role="status" data-testid="tx-status">
          Waiting for Hedera consensus, usually a few seconds.{" "}
          <a className="link link-primary" href={hashscanTx(state.hash)} target="_blank" rel="noreferrer">
            View on HashScan
          </a>
        </p>
      );
    case "success":
      return (
        <p className="m-0 text-sm text-success-content dark:text-success" role="status" data-testid="tx-status">
          {successText ?? "Done."}{" "}
          <a className="link" href={hashscanTx(state.hash)} target="_blank" rel="noreferrer">
            View on HashScan
          </a>
        </p>
      );
    case "failed":
      return (
        <p className="m-0 rounded-lg bg-error/10 px-3 py-2 text-sm text-error" role="alert" data-testid="tx-error">
          {state.message}
          {state.hash && (
            <>
              {" "}
              <a className="link" href={hashscanTx(state.hash)} target="_blank" rel="noreferrer">
                View on HashScan
              </a>
            </>
          )}
        </p>
      );
  }
};
