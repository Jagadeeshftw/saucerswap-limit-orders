"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useQuery } from "@tanstack/react-query";
import { erc20Abi, formatUnits, parseEventLogs } from "viem";
import { usePublicClient } from "wagmi";
import { TxStatus } from "~~/components/orders/TxStatus";
import { type GuardInfo, type MarketInfo, legs, useCheckDelays, useOrderCosts } from "~~/hooks/orders/useMarkets";
import { useCollectionId } from "~~/hooks/orders/useOrders";
import { vault } from "~~/hooks/orders/useVault";
import { useVaultTx } from "~~/hooks/orders/useVaultTx";
import { useWallet } from "~~/hooks/orders/useWallet";
import { budgetFor, checksFor, coverageSeconds, durationText } from "~~/utils/orders/budget";
import { type OrderKind, Side, Trigger, comparatorText, triggerFor } from "~~/utils/orders/orders";
import {
  addressFromEntityId,
  formatAmount,
  formatHbar,
  formatPrice,
  parseAmount,
  parsePrice,
  tinybarToWeibar,
} from "~~/utils/orders/units";

/** HIP-719: an account associates itself with an HTS token by calling associate() on the token. */
const hip719Abi = [
  { type: "function", name: "associate", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "nonpayable" },
] as const;

const EXPIRIES = [
  { label: "1 hour", seconds: 3600 },
  { label: "1 day", seconds: 86_400 },
  { label: "7 days", seconds: 7 * 86_400 },
  { label: "30 days", seconds: 30 * 86_400 },
];

const LIFETIMES = EXPIRIES.map(e => e.seconds);

const Chip = ({
  on,
  onClick,
  children,
  testId,
}: {
  on: boolean;
  onClick: () => void;
  children: React.ReactNode;
  testId?: string;
}) => (
  <button
    type="button"
    onClick={onClick}
    aria-pressed={on}
    data-testid={testId}
    className={`rounded-full border px-3 py-1 text-sm font-semibold ${
      on ? "border-primary bg-primary/10 text-primary" : "border-base-300 bg-base-100 text-base-content/70"
    }`}
  >
    {children}
  </button>
);

const Field = ({
  label,
  hint,
  htmlFor,
  children,
}: {
  label: string;
  hint?: string;
  htmlFor: string;
  children: React.ReactNode;
}) => (
  <div className="grid gap-1.5">
    <label htmlFor={htmlFor} className="flex justify-between gap-2 text-sm font-semibold text-base-content/80">
      {label}
      {hint && <span className="font-medium">{hint}</span>}
    </label>
    {children}
  </div>
);

export const OrderTicket = ({ market, guard }: { market: MarketInfo; guard: GuardInfo | undefined }) => {
  const [side, setSide] = useState<Side>(Side.SellBase);
  const [kind, setKind] = useState<OrderKind>("limit");
  const [amountText, setAmountText] = useState("");
  const [triggerText, setTriggerText] = useState("");
  const [slippageText, setSlippageText] = useState("0.5");
  const [expiry, setExpiry] = useState(EXPIRIES[1].seconds);
  const [placedId, setPlacedId] = useState<bigint>();

  const { input, output } = legs(market, side);
  const trigger = triggerFor(side, kind);
  const costs = useOrderCosts(market.id, side);
  const collectionId = useCollectionId();
  const tokens = useMemo(
    () => [market.base, market.quote].filter(t => !t.isHbar).map(t => ({ address: t.address, entityId: t.entityId })),
    [market],
  );
  const wallet = useWallet(tokens, collectionId);
  const tx = useVaultTx();
  const publicClient = usePublicClient({ chainId: vault.chainId });

  // Suggest a trigger 5% away from the current price whenever the order type changes.
  const oracle = guard?.oraclePrice ?? 0n;
  useEffect(() => {
    if (oracle === 0n) return;
    const up = trigger === Trigger.AtOrAbove;
    setTriggerText(formatPrice((oracle * (up ? 105n : 95n)) / 100n));
  }, [market.id, side, kind, trigger, oracle === 0n]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    setSlippageText(market.maxSlippageBps >= 50 ? "0.5" : (market.maxSlippageBps / 100).toString());
    setPlacedId(undefined);
    tx.reset();
  }, [market.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const amount = parseAmount(amountText, input.decimals);
  const triggerPrice = parsePrice(triggerText);
  const slippageBps = Number.isFinite(Number(slippageText)) ? Math.round(Number(slippageText) * 100) : NaN;
  const minSlippage = Math.floor(market.poolFee / 100) + 1;
  const slippageOk = slippageBps >= minSlippage && slippageBps <= market.maxSlippageBps;

  // The budget pays for every check the order needs until it expires, at the vault's own pace for this trigger.
  const waits = useCheckDelays(market.id, trigger, triggerPrice, LIFETIMES);
  const budgetForLifetime = (index: number) => {
    const wait = waits[index];
    if (!costs || wait === undefined) return undefined;
    return budgetFor(checksFor(LIFETIMES[index], wait), costs.soloCheck, costs.fill, costs.minBudget);
  };
  const expiryIndex = LIFETIMES.indexOf(expiry);
  const wait = waits[expiryIndex];
  const checks = wait !== undefined ? checksFor(expiry, wait) : undefined;
  const budget = budgetForLifetime(expiryIndex);
  const sharedLasts =
    costs?.sharedCheck && budget !== undefined && wait !== undefined
      ? coverageSeconds(budget, costs.fill, costs.sharedCheck, wait)
      : undefined;

  const inputBalance = input.isHbar ? wallet.hbarTinybar : wallet.token(input.address).balance;
  const allowance = input.isHbar ? undefined : wallet.token(input.address).allowance;
  const hbarNeeded = budget !== undefined ? budget + (input.isHbar ? (amount ?? 0n) : 0n) : undefined;
  const expectedOut =
    amount && triggerPrice
      ? side === Side.SellBase
        ? (amount * triggerPrice * 10n ** BigInt(output.decimals)) / (10n ** 8n * 10n ** BigInt(input.decimals))
        : (amount * 10n ** 8n * 10n ** BigInt(output.decimals)) / (triggerPrice * 10n ** BigInt(input.decimals))
      : undefined;
  const minOut =
    expectedOut !== undefined && slippageOk ? (expectedOut * BigInt(10_000 - slippageBps)) / 10_000n : undefined;
  // A limit order can only fill at the trigger or better; a stop can fill past it.
  const guaranteed = kind === "limit";

  const problems: string[] = [];
  if (amountText && amount === null) problems.push(`Enter the amount with at most ${input.decimals} decimals.`);
  if (amount === 0n) problems.push("Enter an amount greater than zero.");
  if (triggerText && (triggerPrice === null || triggerPrice === 0n))
    problems.push("Enter a trigger price greater than zero.");
  if (!slippageOk) problems.push(`Slippage must be between ${minSlippage / 100}% and ${market.maxSlippageBps / 100}%.`);
  if (amount && inputBalance !== undefined && amount > inputBalance) {
    problems.push(`Insufficient ${input.symbol}: you have ${formatAmount(inputBalance, input.decimals)}.`);
  }
  if (hbarNeeded !== undefined && wallet.hbarTinybar !== undefined && hbarNeeded > wallet.hbarTinybar) {
    problems.push(
      `Insufficient HBAR: this order needs ${formatHbar(hbarNeeded)} and you have ${formatHbar(wallet.hbarTinybar)}.`,
    );
  }

  const needsNftAssociation =
    collectionId !== undefined && wallet.associationsReady && !wallet.canReceive(collectionId);
  const needsOutputAssociation = !output.isHbar && wallet.associationsReady && !wallet.canReceive(output.entityId);
  const needsApproval =
    !input.isHbar && amount !== null && amount > 0n && allowance !== undefined && allowance < amount;
  const formReady =
    amount !== null && amount > 0n && triggerPrice && triggerPrice > 0n && slippageOk && budget !== undefined;
  const ready =
    wallet.isConnected &&
    !wallet.wrongNetwork &&
    !wallet.accountMissing &&
    formReady &&
    problems.length === 0 &&
    !needsNftAssociation &&
    !needsOutputAssociation &&
    !needsApproval;

  const params = formReady
    ? {
        marketId: market.id,
        side,
        trigger,
        amountIn: amount!,
        triggerPrice: triggerPrice!,
        slippageBps,
        expiry: Math.floor(Date.now() / 60_000) * 60 + expiry,
      }
    : undefined;
  const value =
    params && budget !== undefined ? tinybarToWeibar(budget + (input.isHbar ? params.amountIn : 0n)) : undefined;

  const fee = useQuery({
    queryKey: ["place-fee", market.id, side, trigger, String(params?.amountIn), String(value), wallet.address],
    enabled: Boolean(ready && params && publicClient && wallet.address),
    retry: false,
    queryFn: async () => {
      const [gas, gasPrice] = await Promise.all([
        publicClient!.estimateContractGas({
          address: vault.address as `0x${string}`,
          abi: vault.abi,
          functionName: "placeOrder",
          args: [params!],
          value,
          account: wallet.address,
        }),
        publicClient!.getGasPrice(),
      ]);
      return gas * gasPrice;
    },
  });

  const associate = (entityId: string) =>
    tx.send({
      address: addressFromEntityId(entityId),
      abi: hip719Abi,
      functionName: "associate",
      chainId: vault.chainId,
    });
  const approve = () =>
    tx.send({
      address: input.address as `0x${string}`,
      abi: erc20Abi,
      functionName: "approve",
      args: [vault.address as `0x${string}`, amount!],
      chainId: vault.chainId,
    });
  const place = async () => {
    const receipt = await tx.send({
      address: vault.address as `0x${string}`,
      abi: vault.abi,
      functionName: "placeOrder",
      args: [params!],
      value,
      chainId: vault.chainId,
    });
    const placed = receipt && parseEventLogs({ abi: vault.abi, logs: receipt.logs, eventName: "OrderPlaced" })[0];
    if (placed) setPlacedId(placed.args.orderId);
  };

  const verb = side === Side.SellBase ? "Sell" : "Buy";
  const whenLabel =
    side === Side.SellBase
      ? `Sell when ${market.base.symbol} is ${comparatorText(trigger)}`
      : `Buy ${market.base.symbol} when price is ${comparatorText(trigger)}`;

  return (
    <section className="grid gap-4 rounded-2xl border border-base-300 bg-base-100 p-5" aria-label="New order">
      <h2 className="m-0 text-xs font-semibold tracking-wide text-base-content/70 uppercase">New order</h2>
      <div className="grid grid-cols-2 gap-1 rounded-full border border-base-300 bg-base-200 p-1" role="tablist">
        {[Side.SellBase, Side.BuyBase].map(s => (
          <button
            key={s}
            type="button"
            role="tab"
            aria-selected={side === s}
            data-testid={s === Side.SellBase ? "side-sell" : "side-buy"}
            onClick={() => setSide(s)}
            className={`rounded-full py-2 text-sm font-semibold ${side === s ? "bg-base-100 shadow-sm" : "text-base-content/70"}`}
          >
            {s === Side.SellBase ? "Sell" : "Buy"} {market.base.symbol}
          </button>
        ))}
      </div>

      <Field label="Order type" htmlFor="kind">
        <div className="flex flex-wrap gap-1.5" id="kind">
          <Chip on={kind === "limit"} onClick={() => setKind("limit")} testId="kind-limit">
            {side === Side.SellBase ? "Limit sell (take profit)" : "Limit buy"}
          </Chip>
          <Chip on={kind === "stop"} onClick={() => setKind("stop")} testId="kind-stop">
            {side === Side.SellBase ? "Stop-loss" : "Stop-buy"}
          </Chip>
        </div>
      </Field>

      <Field
        label={side === Side.SellBase ? "Amount" : `Spend`}
        hint={
          inputBalance !== undefined
            ? `Balance ${formatAmount(inputBalance, input.decimals)} ${input.symbol}`
            : undefined
        }
        htmlFor="amount"
      >
        <div className="input input-bordered flex w-full items-center gap-2 rounded-full">
          <input
            id="amount"
            inputMode="decimal"
            placeholder="0.00"
            className="grow font-mono tabular-nums"
            value={amountText}
            onChange={e => setAmountText(e.target.value)}
          />
          <span className="text-sm font-semibold text-base-content/70">{input.symbol}</span>
        </div>
      </Field>

      <Field label={whenLabel} hint={oracle > 0n ? `now ${formatPrice(oracle)}` : undefined} htmlFor="trigger">
        <div className="input input-bordered flex w-full items-center gap-2 rounded-full">
          <input
            id="trigger"
            inputMode="decimal"
            className="grow font-mono tabular-nums"
            value={triggerText}
            onChange={e => setTriggerText(e.target.value)}
          />
          <span className="text-sm font-semibold text-base-content/70">{market.quote.symbol}</span>
        </div>
      </Field>

      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Max slippage" htmlFor="slippage">
          <div className="input input-bordered flex w-full items-center gap-2 rounded-full">
            <input
              id="slippage"
              inputMode="decimal"
              className="grow font-mono tabular-nums"
              value={slippageText}
              onChange={e => setSlippageText(e.target.value)}
            />
            <span className="text-sm font-semibold text-base-content/70">%</span>
          </div>
        </Field>
        <Field label="Expires in" htmlFor="expiry">
          <select
            id="expiry"
            className="select select-bordered w-full rounded-full"
            value={expiry}
            onChange={e => setExpiry(Number(e.target.value))}
          >
            {EXPIRIES.map((e, i) => {
              const cost = budgetForLifetime(i);
              return (
                <option key={e.seconds} value={e.seconds}>
                  {cost !== undefined ? `${e.label} · ${formatHbar(cost, 2)} budget` : e.label}
                </option>
              );
            })}
          </select>
        </Field>
      </div>

      <div
        className="grid gap-2 rounded-xl border border-dashed border-base-300 bg-base-200 p-4 text-sm leading-relaxed"
        data-testid="ticket-summary"
      >
        {amount && triggerPrice && expectedOut !== undefined ? (
          <span>
            {verb}s{" "}
            <b className="font-mono">
              {formatAmount(amount, input.decimals)} {input.symbol}
            </b>{" "}
            when Chainlink shows {market.base.symbol} {comparatorText(trigger)}{" "}
            <b className="font-mono">
              {formatPrice(triggerPrice)} {market.quote.symbol}
            </b>
            .{" "}
            {guaranteed ? (
              <>
                You receive at least{" "}
                <b className="font-mono">
                  {minOut !== undefined ? formatAmount(minOut, output.decimals) : "–"} {output.symbol}
                </b>
                .
              </>
            ) : (
              <>
                About{" "}
                <b className="font-mono">
                  {formatAmount(expectedOut, output.decimals)} {output.symbol}
                </b>{" "}
                at the trigger; a stop can fill past it, and never below Chainlink&apos;s price at fill minus{" "}
                {slippageOk ? slippageBps / 100 : "–"}%.
              </>
            )}
          </span>
        ) : (
          <span>Enter an amount and trigger to see what this order does.</span>
        )}
        {costs && budget !== undefined && wait !== undefined && checks !== undefined && (
          <span className="text-base-content/80" data-testid="budget-line">
            Check budget <b className="font-mono">{formatHbar(budget)}</b> covers the whole{" "}
            {EXPIRIES[expiryIndex].label}: at today&apos;s price the market checks this order about every{" "}
            {durationText(wait)}, so {checks} {checks === 1 ? "check" : "checks"} at {formatHbar(costs.soloCheck)} each
            while it is the only open order, plus {formatHbar(costs.fill)} held back for the fill and the last check.
            Checks come faster as the price nears your trigger; if the budget runs out the order shows{" "}
            <i>Budget empty</i> and you can top it up.
            {costs.sharedCheck !== undefined && costs.fundedOrders > 0 && sharedLasts !== undefined && (
              <>
                {" "}
                Shared with {costs.fundedOrders} other {costs.fundedOrders === 1 ? "order" : "orders"} right now, it
                lasts about {durationText(sharedLasts)}.
              </>
            )}{" "}
            Unused budget is refunded.
          </span>
        )}
        {fee.data !== undefined && (
          <span className="text-base-content/80">
            Placing it costs about <b className="font-mono">{formatAmount(fee.data, 18, 3)} HBAR</b> in network fees
            (minting the order NFT).
          </span>
        )}
      </div>

      {problems.map(p => (
        <p key={p} className="m-0 text-sm text-error" role="alert" data-testid="ticket-problem">
          {p}
        </p>
      ))}

      {!wallet.isConnected ? (
        <ConnectButton.Custom>
          {({ openConnectModal }) => (
            <button type="button" className="btn btn-primary w-full rounded-full" onClick={openConnectModal}>
              Connect wallet
            </button>
          )}
        </ConnectButton.Custom>
      ) : (
        <div className="grid gap-2 text-sm" data-testid="ticket-checklist">
          {wallet.accountMissing && (
            <p className="m-0 text-error">
              This address has no Hedera testnet account yet. Send it testnet HBAR from the{" "}
              <a className="link" href="https://portal.hedera.com/faucet" target="_blank" rel="noreferrer">
                Hedera Portal faucet
              </a>{" "}
              and it will be created.
            </p>
          )}
          {needsNftAssociation && (
            <div className="flex items-center justify-between gap-2">
              <span>Associate the order NFT collection ({collectionId})</span>
              <button
                type="button"
                className="btn btn-outline btn-sm rounded-full"
                disabled={tx.busy}
                onClick={() => associate(collectionId!)}
              >
                Associate
              </button>
            </div>
          )}
          {needsOutputAssociation && (
            <div className="flex items-center justify-between gap-2">
              <span>
                Associate {output.symbol} ({output.entityId}) so you can receive it
              </span>
              <button
                type="button"
                className="btn btn-outline btn-sm rounded-full"
                disabled={tx.busy}
                onClick={() => associate(output.entityId)}
              >
                Associate
              </button>
            </div>
          )}
          {needsApproval && (
            <div className="flex items-center justify-between gap-2">
              <span>
                Let the vault take {formatUnits(amount!, input.decimals)} {input.symbol}
              </span>
              <button
                type="button"
                className="btn btn-outline btn-sm rounded-full"
                disabled={tx.busy}
                onClick={approve}
              >
                Approve
              </button>
            </div>
          )}
          <button
            type="button"
            className="btn btn-primary w-full rounded-full"
            disabled={!ready || tx.busy}
            onClick={place}
            data-testid="place-order"
          >
            {tx.state.status === "signing"
              ? "Confirm in wallet"
              : tx.state.status === "confirming"
                ? "Placing order"
                : "Place order"}
          </button>
        </div>
      )}

      <TxStatus state={tx.state} successText={placedId !== undefined ? undefined : "Done."} />
      {placedId !== undefined && (
        <p className="m-0 text-sm" data-testid="placed">
          Order #{placedId.toString()} placed.{" "}
          <Link className="link link-primary" href={`/orders/${placedId}`}>
            Follow it
          </Link>
        </p>
      )}
    </section>
  );
};
