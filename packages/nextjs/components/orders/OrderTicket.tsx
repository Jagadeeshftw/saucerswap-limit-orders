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
import {
  budgetFor,
  checksAffordable,
  checksFor,
  checksWhileHeld,
  coverageSeconds,
  durationText,
  durationWords,
  heldSeconds,
} from "~~/utils/orders/budget";
import { GAS_LIMIT, maxFee } from "~~/utils/orders/gas";
import {
  GuardState,
  MAX_TRAIL_BPS,
  MIN_TRAIL_BPS,
  type OrderKind,
  Side,
  Trigger,
  comparatorText,
  orderKind,
  orderTypeFor,
  placeLabel,
  trailingTrigger,
  triggerFor,
} from "~~/utils/orders/orders";
import {
  addressFromEntityId,
  formatAmount,
  formatBps,
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

/** One option of a segmented control: the selected one is raised, the rest recede. */
const Segment = ({
  on,
  onClick,
  children,
  testId,
  disabled,
  title,
}: {
  on: boolean;
  onClick: () => void;
  children: React.ReactNode;
  testId?: string;
  disabled?: boolean;
  title?: string;
}) => (
  <button
    type="button"
    onClick={onClick}
    aria-pressed={on}
    data-testid={testId}
    disabled={disabled}
    title={title}
    className={`rounded-full px-2 py-1.5 text-sm font-semibold disabled:cursor-not-allowed disabled:opacity-40 ${
      on ? "bg-base-100 text-base-content shadow-sm" : "text-base-content/70"
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
    <label
      htmlFor={htmlFor}
      className="flex flex-wrap justify-between gap-x-2 text-xs font-semibold tracking-wide text-base-content/70 uppercase"
    >
      {label}
      {hint && <span className="font-semibold tracking-normal normal-case">{hint}</span>}
    </label>
    {children}
  </div>
);

/** A value box with its unit on the right, the shape every ticket input shares. */
const UnitInput = ({
  id,
  value,
  onChange,
  unit,
  placeholder,
}: {
  id: string;
  value: string;
  onChange: (value: string) => void;
  unit: string;
  placeholder?: string;
}) => (
  <div className="input input-bordered flex w-full items-center gap-2 rounded-xl bg-base-200">
    <input
      id={id}
      inputMode="decimal"
      placeholder={placeholder}
      className="grow font-mono text-base font-semibold tabular-nums"
      value={value}
      onChange={e => onChange(e.target.value)}
    />
    <span className="text-xs font-semibold text-base-content/70">{unit}</span>
  </div>
);

/** A budget rounded up to 4 decimals, so a figure on screen never asks for less than the vault needs. */
const roundUp = (tinybar: bigint) => ((tinybar + 9_999n) / 10_000n) * 10_000n;
const budgetText = (tinybar: bigint) => formatAmount(roundUp(tinybar), 8).replace(/,/g, "");

export const OrderTicket = ({ market, guard }: { market: MarketInfo; guard: GuardInfo | undefined }) => {
  const [side, setSide] = useState<Side>(Side.SellBase);
  const [kind, setKind] = useState<OrderKind>("limit");
  const [amountText, setAmountText] = useState("");
  const [triggerText, setTriggerText] = useState("");
  const [trailText, setTrailText] = useState("2.5");
  const [slippageText, setSlippageText] = useState("0.5");
  const [expiry, setExpiry] = useState(EXPIRIES[1].seconds);
  // Until the maker types a budget, it follows the one that covers the whole expiry.
  const [budgetInput, setBudgetInput] = useState<string>();
  const [placedId, setPlacedId] = useState<bigint>();

  const { input, output } = legs(market, side);
  const trailing = kind === "trailing";
  const orderType = orderTypeFor(kind);
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

  // A trailing stop sells into a pullback; there is no buy-side trailing type, so a buy falls back to a limit.
  useEffect(() => {
    if (side === Side.BuyBase && kind === "trailing") setKind("limit");
  }, [side, kind]);

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
    setBudgetInput(undefined);
    tx.reset();
  }, [market.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const amount = parseAmount(amountText, input.decimals);
  const trailPercent = Number(trailText);
  const trailBps = trailText.trim() !== "" && Number.isFinite(trailPercent) ? Math.round(trailPercent * 100) : NaN;
  const trailOk = trailBps >= MIN_TRAIL_BPS && trailBps <= MAX_TRAIL_BPS;
  // A trailing stop's trigger starts at today's price less the trail and only ever rises with the peak.
  const triggerPrice = trailing
    ? trailOk && oracle > 0n
      ? trailingTrigger(oracle, BigInt(trailBps))
      : null
    : parsePrice(triggerText);
  const typeParam = trailing ? (trailOk ? BigInt(trailBps) : null) : triggerPrice;
  const slippageBps = Number.isFinite(Number(slippageText)) ? Math.round(Number(slippageText) * 100) : NaN;
  const minSlippage = Math.floor(market.poolFee / 100) + 1;
  const slippageOk = slippageBps >= minSlippage && slippageBps <= market.maxSlippageBps;

  // The budget pays for every check the order needs until it expires, at the vault's own pace for this trigger.
  const waits = useCheckDelays(market.id, orderType, side, typeParam, LIFETIMES);
  // An order whose trigger is already met fills on its first check if the guard is open; if the guard holds it,
  // the vault backs off instead of checking every few minutes. Otherwise it is checked at the vault's pace.
  const triggeredNow =
    !trailing && triggerPrice !== null && triggerPrice > 0n && oracle > 0n
      ? trigger === Trigger.AtOrAbove
        ? oracle >= triggerPrice
        : oracle <= triggerPrice
      : false;
  const checksOver = (index: number) => {
    const wait = waits[index];
    if (wait === undefined) return undefined;
    if (!triggeredNow) return checksFor(LIFETIMES[index], wait);
    return guard?.state === GuardState.Open
      ? 1
      : checksWhileHeld(LIFETIMES[index], market.minInterval, market.maxInterval);
  };
  const budgetForLifetime = (index: number) => {
    const checks = checksOver(index);
    if (!costs || checks === undefined) return undefined;
    return budgetFor(checks, costs.soloCheck, costs.fill, costs.minBudget);
  };
  const expiryIndex = LIFETIMES.indexOf(expiry);
  const wait = waits[expiryIndex];
  const checks = checksOver(expiryIndex);
  const suggested = budgetForLifetime(expiryIndex);
  const suggestedText = suggested !== undefined ? budgetText(suggested) : "";
  const budget =
    budgetInput === undefined
      ? suggested !== undefined
        ? parseAmount(suggestedText, 8)!
        : undefined
      : (parseAmount(budgetInput, 8) ?? undefined);
  const budgetTooLow = budget !== undefined && costs !== undefined && budget < costs.minBudget;
  // How long the budget keeps the order checked at the vault's pace, never past its expiry.
  const affordable = budget !== undefined && costs ? checksAffordable(budget, costs.fill, costs.soloCheck) : undefined;
  const coversSeconds =
    affordable === undefined || wait === undefined
      ? undefined
      : Math.min(
          expiry,
          !triggeredNow
            ? affordable * wait
            : guard?.state === GuardState.Open
              ? expiry
              : heldSeconds(affordable, market.minInterval, market.maxInterval),
        );
  const coversWhole = coversSeconds !== undefined && coversSeconds >= expiry;
  const sharedLasts =
    costs?.sharedCheck && budget !== undefined && wait !== undefined
      ? coverageSeconds(budget, costs.fill, costs.sharedCheck, wait)
      : undefined;

  const inputBalance = input.isHbar ? wallet.hbarTinybar : wallet.token(input.address).balance;
  const allowance = input.isHbar ? undefined : wallet.token(input.address).allowance;
  // The relay's gas estimates undercount HTS and HSS work, so the fee is bounded by the measured limit instead.
  const { data: gasPrice } = useQuery({
    queryKey: ["gas-price"],
    queryFn: () => publicClient!.getGasPrice(),
    enabled: Boolean(publicClient),
    refetchInterval: 60_000,
  });
  const placeFee = gasPrice !== undefined ? maxFee(GAS_LIMIT.placeOrder, gasPrice) : undefined;
  const placeFeeTinybar = placeFee !== undefined ? placeFee / 10n ** 10n : 0n;
  const hbarNeeded = budget !== undefined ? budget + (input.isHbar ? (amount ?? 0n) : 0n) + placeFeeTinybar : undefined;
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
  const actionLabel = placeLabel(side, orderType);

  const problems: string[] = [];
  if (amountText && amount === null) problems.push(`Enter the amount with at most ${input.decimals} decimals.`);
  if (amount === 0n) problems.push("Enter an amount greater than zero.");
  if (!trailing && triggerText && (triggerPrice === null || triggerPrice === 0n))
    problems.push("Enter a trigger price greater than zero.");
  if (trailing && !trailOk)
    problems.push(`The trail must be between ${formatBps(MIN_TRAIL_BPS)} and ${formatBps(MAX_TRAIL_BPS)}.`);
  if (!slippageOk) problems.push(`Slippage must be between ${minSlippage / 100}% and ${market.maxSlippageBps / 100}%.`);
  if (budgetInput !== undefined && budget === undefined)
    problems.push("Enter the check budget in HBAR, at most 8 decimals.");
  if (amount && inputBalance !== undefined && amount > inputBalance) {
    problems.push(`Insufficient ${input.symbol}: you have ${formatAmount(inputBalance, input.decimals)}.`);
  }
  if (hbarNeeded !== undefined && wallet.hbarTinybar !== undefined && hbarNeeded > wallet.hbarTinybar) {
    problems.push(
      `Insufficient HBAR: this order needs ${formatHbar(hbarNeeded)} including network fees, and you have ${formatHbar(wallet.hbarTinybar)}.`,
    );
  }

  const needsNftAssociation =
    collectionId !== undefined && wallet.associationsReady && !wallet.canReceive(collectionId);
  const needsOutputAssociation = !output.isHbar && wallet.associationsReady && !wallet.canReceive(output.entityId);
  const needsApproval =
    !input.isHbar && amount !== null && amount > 0n && allowance !== undefined && allowance < amount;
  const formReady =
    amount !== null &&
    amount > 0n &&
    typeParam !== null &&
    typeParam > 0n &&
    (trailing || (triggerPrice !== null && triggerPrice > 0n)) &&
    slippageOk &&
    budget !== undefined &&
    !budgetTooLow;
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
        orderType,
        amountIn: amount!,
        typeParam: typeParam!,
        slippageBps,
        expiry: Math.floor(Date.now() / 60_000) * 60 + expiry,
      }
    : undefined;
  const value =
    params && budget !== undefined ? tinybarToWeibar(budget + (input.isHbar ? params.amountIn : 0n)) : undefined;

  const associate = (entityId: string) =>
    tx.send({
      address: addressFromEntityId(entityId),
      abi: hip719Abi,
      functionName: "associate",
      chainId: vault.chainId,
      gas: GAS_LIMIT.associate,
    });
  const approve = () =>
    tx.send({
      address: input.address as `0x${string}`,
      abi: erc20Abi,
      functionName: "approve",
      args: [vault.address as `0x${string}`, amount!],
      chainId: vault.chainId,
      gas: GAS_LIMIT.approve,
    });
  const place = async () => {
    const receipt = await tx.send({
      address: vault.address as `0x${string}`,
      abi: vault.abi,
      functionName: "placeOrder",
      args: [params!],
      value,
      chainId: vault.chainId,
      gas: GAS_LIMIT.placeOrder,
    });
    const placed = receipt && parseEventLogs({ abi: vault.abi, logs: receipt.logs, eventName: "OrderPlaced" })[0];
    if (placed) setPlacedId(placed.args.orderId);
  };

  const verb = side === Side.SellBase ? "Sell" : "Buy";
  const whenLabel =
    side === Side.SellBase
      ? `Sell when ${market.base.symbol} is ${comparatorText(trigger)}`
      : `Buy ${market.base.symbol} when price is ${comparatorText(trigger)}`;
  const KIND_NOTE: Record<OrderKind, string> = {
    limit: "fills at your price or better",
    stop:
      side === Side.SellBase ? "sells if the price falls to your trigger" : "buys if the price rises to your trigger",
    trailing: "a stop that follows the price up",
  };

  return (
    <section className="grid gap-4 rounded-2xl border border-base-300 bg-base-100 p-4 sm:p-5" aria-label="New order">
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
            className={`rounded-full py-2 text-sm font-semibold ${side === s ? "bg-base-100 text-base-content shadow-sm" : "text-base-content/70"}`}
          >
            {s === Side.SellBase ? "Sell" : "Buy"} {market.base.symbol}
          </button>
        ))}
      </div>

      <div className="grid gap-1.5">
        <div
          className="grid grid-cols-3 gap-1 rounded-full border border-base-300 bg-base-200 p-1"
          role="group"
          aria-label="Order type"
        >
          <Segment on={kind === "limit"} onClick={() => setKind("limit")} testId="kind-limit">
            Limit
          </Segment>
          <Segment on={kind === "stop"} onClick={() => setKind("stop")} testId="kind-stop">
            Stop
          </Segment>
          <Segment
            on={trailing}
            onClick={() => setKind("trailing")}
            testId="kind-trailing"
            disabled={side === Side.BuyBase}
            title={
              side === Side.BuyBase ? "A trailing stop sells into a pullback; switch to Sell to use it." : undefined
            }
          >
            Trailing
          </Segment>
        </div>
        <p className="m-0 px-1 text-xs text-base-content/70" data-testid="kind-note">
          <b className="font-semibold text-base-content">{orderKind(side, orderType)}</b>: {KIND_NOTE[kind]}
        </p>
      </div>

      <Field
        label={side === Side.SellBase ? "Sell" : "Spend"}
        hint={
          inputBalance !== undefined
            ? `balance ${formatAmount(inputBalance, input.decimals)} ${input.symbol}`
            : undefined
        }
        htmlFor="amount"
      >
        <UnitInput id="amount" placeholder="0.00" value={amountText} onChange={setAmountText} unit={input.symbol} />
      </Field>

      {trailing ? (
        <Field label="Trail distance" hint="from the peak" htmlFor="trail">
          <UnitInput id="trail" value={trailText} onChange={setTrailText} unit="%" />
          <span className="px-1 text-xs text-base-content/70" data-testid="trail-hint">
            Ratchets up as {market.base.symbol} rises, fires on a {trailOk ? formatBps(trailBps) : "–"} pullback
            {triggerPrice !== null && (
              <>
                {" "}
                · trigger starts at{" "}
                <span className="font-mono">
                  {formatPrice(triggerPrice)} {market.quote.symbol}
                </span>
              </>
            )}
          </span>
        </Field>
      ) : (
        <Field label={whenLabel} hint={oracle > 0n ? `now ${formatPrice(oracle)}` : undefined} htmlFor="trigger">
          <UnitInput id="trigger" value={triggerText} onChange={setTriggerText} unit={market.quote.symbol} />
        </Field>
      )}

      <div className="grid grid-cols-[minmax(0,2fr)_minmax(0,3fr)] gap-3">
        <Field label="Max slippage" htmlFor="slippage">
          <UnitInput id="slippage" value={slippageText} onChange={setSlippageText} unit="%" />
        </Field>
        <Field label="Expires in" htmlFor="expiry">
          <select
            id="expiry"
            className="select select-bordered w-full rounded-xl bg-base-200"
            value={expiry}
            onChange={e => setExpiry(Number(e.target.value))}
          >
            {EXPIRIES.map((e, i) => {
              const cost = budgetForLifetime(i);
              return (
                <option key={e.seconds} value={e.seconds}>
                  {cost !== undefined ? `${e.label} · ${formatHbar(cost, 2)}` : e.label}
                </option>
              );
            })}
          </select>
        </Field>
      </div>

      <Field
        label="Check budget"
        hint={
          budget !== undefined && coversSeconds !== undefined && !budgetTooLow
            ? `covers ~${durationWords(coversSeconds)}`
            : undefined
        }
        htmlFor="budget"
      >
        <UnitInput
          id="budget"
          value={budgetInput ?? suggestedText}
          onChange={setBudgetInput}
          unit="HBAR"
          placeholder={suggested === undefined ? "enter the order first" : undefined}
        />
        {budgetInput !== undefined && suggested !== undefined && budgetInput !== suggestedText && (
          <button
            type="button"
            className="link w-fit px-1 text-xs text-base-content/70"
            onClick={() => setBudgetInput(undefined)}
          >
            Use {formatHbar(suggested, 2)}, enough for the whole {EXPIRIES[expiryIndex].label}
          </button>
        )}
      </Field>

      {budgetTooLow && costs && (
        <div
          className="grid gap-0.5 rounded-xl border border-error/50 bg-error/10 px-3.5 py-2.5"
          role="alert"
          data-testid="budget-too-low"
        >
          <b className="text-sm text-error-content dark:text-error">Budget too low for this order</b>
          <span className="text-xs">
            Needs at least <b className="font-mono">{formatHbar(roundUp(costs.minBudget))}</b> of check budget; you
            entered <b className="font-mono">{formatHbar(budget!)}</b>. The vault keeps that much back to pay for the
            fill and its first checks.
          </span>
        </div>
      )}

      <div
        className="grid gap-2 rounded-xl border border-dashed border-base-300 bg-base-200 p-4 text-sm leading-relaxed"
        data-testid="ticket-summary"
      >
        {trailing && amount && triggerPrice && expectedOut !== undefined ? (
          <span>
            Sells{" "}
            <b className="font-mono">
              {formatAmount(amount, input.decimals)} {input.symbol}
            </b>{" "}
            when Chainlink falls <b className="font-mono">{formatBps(trailBps)}</b> below the highest price seen at a
            check. Today that is{" "}
            <b className="font-mono">
              {formatPrice(triggerPrice)} {market.quote.symbol}
            </b>
            ; as {market.base.symbol} rises the trigger rises with it, and it never falls. About{" "}
            <b className="font-mono">
              {formatAmount(expectedOut, output.decimals)} {output.symbol}
            </b>{" "}
            at today&apos;s trigger; like a stop it can fill past it, never below Chainlink&apos;s price at fill minus{" "}
            {slippageOk ? slippageBps / 100 : "–"}%. The peak is sampled at scheduled checks, so a spike that comes and
            goes between two checks is not caught.
          </span>
        ) : amount && triggerPrice && expectedOut !== undefined ? (
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
          <span>
            {trailing
              ? "Enter an amount and a trail to see what this order does."
              : "Enter an amount and trigger to see what this order does."}
          </span>
        )}
        {costs && budget !== undefined && !budgetTooLow && wait !== undefined && checks !== undefined && (
          <span className="text-base-content/80" data-testid="budget-line">
            Check budget <b className="font-mono">{formatHbar(budget)}</b>{" "}
            {coversWhole ? (
              <>covers the whole {EXPIRIES[expiryIndex].label}: </>
            ) : (
              <>
                covers about {coversSeconds !== undefined ? durationWords(coversSeconds) : "–"} of the{" "}
                {EXPIRIES[expiryIndex].label}, then the order shows <i>Budget empty</i> until you top it up:{" "}
              </>
            )}
            {!triggeredNow ? (
              <>
                at today&apos;s price the market checks this order about every {durationText(wait)}, so {checks}{" "}
                {checks === 1 ? "check" : "checks"} over the whole time
              </>
            ) : guard?.state === GuardState.Open ? (
              <>the trigger is already met, so it should fill on the next scheduled check, about 1 check</>
            ) : (
              <>
                the trigger is already met but the guard is holding this market, so checks back off from{" "}
                {durationText(market.minInterval * 2)} to every {durationText(market.maxInterval)}: {checks} checks
              </>
            )}{" "}
            at {formatHbar(costs.soloCheck)} each while it is the only open order, plus {formatHbar(costs.fill)} held
            back for the fill and the last check. Checks come faster as the price nears your trigger; if the budget runs
            out the order shows <i>Budget empty</i> and you can top it up.
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
      </div>

      {placeFee !== undefined && (
        <div className="flex justify-between gap-3 px-1 text-sm" data-testid="fee-line">
          <span className="text-base-content/70">Network fee, upper bound</span>
          <b className="font-mono font-semibold tabular-nums">≤ {formatAmount(placeFee, 18, 3)} HBAR</b>
        </div>
      )}

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
                : actionLabel}
          </button>
        </div>
      )}

      <p className="m-0 text-center text-xs text-base-content/70">You keep the NFT · unused budget refunds on fill</p>
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
