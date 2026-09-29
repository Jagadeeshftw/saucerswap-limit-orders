"use client";

import { useAccount, useSwitchChain } from "wagmi";
import { useMirrorLag } from "~~/hooks/orders/useOrders";
import { vault } from "~~/hooks/orders/useVault";
import { type DisplayStatus, GUARD_COPY, type GuardState, STATUS_LABEL } from "~~/utils/orders/orders";

/** Network indicator shown in the header at every width. */
export const NetworkPill = () => {
  const { isConnected, chainId } = useAccount();
  const wrong = isConnected && chainId !== vault.chainId;
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-semibold whitespace-nowrap ${
        wrong ? "border-error text-error" : "border-base-300"
      }`}
      data-testid="network-pill"
    >
      <span className={`h-2 w-2 rounded-full ${wrong ? "bg-error" : "bg-success"}`} aria-hidden />
      {wrong ? (
        "Wrong network"
      ) : (
        <>
          <span className="sm:hidden">Testnet</span>
          <span className="hidden sm:inline">Hedera Testnet</span>
        </>
      )}
    </span>
  );
};

/** Full-width prompt when the wallet is on another chain; the vault only exists on Hedera testnet. */
export const WrongNetworkBanner = () => {
  const { isConnected, chainId } = useAccount();
  const { switchChain, isPending } = useSwitchChain();
  if (!isConnected || chainId === vault.chainId) return null;
  return (
    <div role="alert" className="bg-error/10 border-b border-error/40 px-4 py-3 text-sm" data-testid="wrong-network">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3">
        <span>
          Your wallet is on another network. Orders live on <b>Hedera Testnet</b> (chain 296).
        </span>
        <button
          type="button"
          className="btn btn-error btn-sm"
          disabled={isPending}
          onClick={() => switchChain({ chainId: vault.chainId })}
        >
          {isPending ? "Check your wallet" : "Switch to Hedera Testnet"}
        </button>
      </div>
    </div>
  );
};

/** Warns when mirror-node data (order lists, trails) is behind consensus by more than a few seconds. */
export const MirrorLagNotice = () => {
  const { data: lag } = useMirrorLag();
  if (lag === undefined || lag < 10) return null;
  return (
    <p className="text-xs text-base-content/70" data-testid="mirror-lag">
      Status may be up to {lag} s behind: the mirror node is catching up with the network.
    </p>
  );
};

const STATUS_CLASS: Record<DisplayStatus, string> = {
  open: "bg-info/15 text-info",
  held: "bg-warning/25 text-warning-content dark:text-warning",
  "budget-empty": "bg-error/15 text-error",
  filled: "bg-success/20 text-success-content dark:text-success",
  cancelled: "bg-base-300 text-base-content/70",
  expired: "bg-base-300 text-base-content/70",
};

export const StatusBadge = ({ status }: { status: DisplayStatus }) => (
  <span
    className={`inline-flex rounded-full px-2.5 py-0.5 text-xs font-semibold whitespace-nowrap ${STATUS_CLASS[status]}`}
  >
    {STATUS_LABEL[status]}
  </span>
);

const TONE_CLASS = {
  ok: "bg-success/15 border-success/50",
  warn: "bg-warning/20 border-warning/60",
  error: "bg-error/10 border-error/60",
};

export const GuardBanner = ({ state }: { state: GuardState }) => {
  const copy = GUARD_COPY[state];
  return (
    <div
      className={`flex items-start gap-3 rounded-xl border px-4 py-3 ${TONE_CLASS[copy.tone]}`}
      data-testid="guard-banner"
    >
      <span
        className={`rounded-full border px-2.5 py-0.5 text-xs font-bold whitespace-nowrap ${
          copy.tone === "ok" ? "border-success text-success-content dark:text-success" : "border-error text-error"
        }`}
      >
        {copy.label}
      </span>
      <p className="m-0 text-sm leading-relaxed">{copy.detail}</p>
    </div>
  );
};
