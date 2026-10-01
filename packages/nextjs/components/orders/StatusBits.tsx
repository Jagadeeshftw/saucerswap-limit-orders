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

// Open is calm (success), Held warns, Filled is the brand colour, Budget empty asks for action; settled is muted.
const STATUS_CLASS: Record<DisplayStatus, string> = {
  open: "bg-success/20 text-success-content dark:text-success",
  held: "bg-warning/30 text-warning-content dark:text-warning",
  "budget-empty": "bg-error/20 text-error-content dark:text-error",
  filled: "bg-primary/15 text-primary",
  cancelled: "bg-base-300 text-base-content/70",
  expired: "bg-base-300 text-base-content/70",
};

/** Longer wording for a chip, shown on hover and read by screen readers. */
const STATUS_TITLE: Partial<Record<DisplayStatus, string>> = {
  held: "Held by guard: the trigger is met, but the pool and Chainlink disagree, so the fill waits",
  "budget-empty": "The budget only covers the fill, so checks are paused until you top it up",
};

export const StatusBadge = ({ status }: { status: DisplayStatus }) => (
  <span
    className={`inline-flex rounded-full px-2.5 py-0.5 text-xs font-bold whitespace-nowrap ${STATUS_CLASS[status]}`}
    title={STATUS_TITLE[status]}
    data-testid="status-chip"
  >
    {STATUS_LABEL[status]}
  </span>
);

const TONE_CLASS = {
  ok: "bg-success/15 border-success/50 text-success-content dark:text-success",
  warn: "bg-warning/20 border-warning/60 text-warning-content dark:text-warning",
  error: "bg-error/10 border-error/60 text-error-content dark:text-error",
};

const DOT_CLASS = { ok: "bg-success", warn: "bg-warning", error: "bg-error" };

/** The guard verdict first, in colour and words; `facts` is the live reading behind it. */
export const GuardBanner = ({ state, facts }: { state: GuardState; facts?: string }) => {
  const copy = GUARD_COPY[state];
  return (
    <div
      className={`flex items-start gap-3 rounded-xl border px-4 py-3 ${TONE_CLASS[copy.tone]}`}
      data-testid="guard-banner"
    >
      <span className={`mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full ${DOT_CLASS[copy.tone]}`} aria-hidden />
      <div className="grid gap-0.5">
        <b className="text-sm font-bold">{copy.label}</b>
        {facts && <span className="text-xs font-semibold opacity-90">{facts}</span>}
        <p className="m-0 text-sm leading-relaxed text-base-content/80">{copy.detail}</p>
      </div>
    </div>
  );
};
