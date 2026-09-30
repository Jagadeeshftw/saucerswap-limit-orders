import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";
import { formatHbar } from "~~/utils/orders/units";

/** HAPI response codes the vault can surface through HtsError. */
const HTS_CODES: Record<number, string> = {
  184: "your account is not associated with the order NFT collection",
};

const HTS_OPERATION = ["creating the collection", "minting the order NFT", "sending you the order NFT", "associating"];

/**
 * Turn a failed wallet or contract call into one sentence that says what went wrong and what to do.
 * Vault custom errors are matched by name; anything else falls back to viem's short message.
 */
export const explainError = (error: unknown): string => {
  if (!(error instanceof BaseError)) return error instanceof Error ? error.message : "Something went wrong.";
  if (error.walk(e => e instanceof UserRejectedRequestError)) return "You rejected the request in your wallet.";

  const revert = error.walk(e => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
  const name = revert?.data?.errorName;
  const args = (revert?.data?.args ?? []) as readonly unknown[];
  switch (name) {
    case "InsufficientBudget":
      return `The check budget is too small: send at least ${formatHbar(args[1] as bigint)}.`;
    case "WrongValue":
      return "The HBAR sent does not cover the order amount. Refresh and try again.";
    case "InvalidSlippage":
      return `Slippage must be between ${Number(args[1]) / 100}% and ${Number(args[2]) / 100}% for this market.`;
    case "InvalidExpiry":
      return "The expiry must be in the future and at most 90 days away.";
    case "InvalidAmount":
      return "Enter an amount greater than zero.";
    case "InvalidTrigger":
      return "Enter a trigger price greater than zero.";
    case "MarketInactive":
      return "This market is paused for new orders.";
    case "NotHolder":
      return "Only the account holding this order's NFT can cancel it.";
    case "OrderNotOpen":
      return "This order is already settled.";
    case "NothingToClaim":
      return "There is nothing to claim.";
    case "TransferFailed":
      return "A token transfer failed. Check your balance and that the vault is approved to spend it.";
    case "SweepAlive":
      return "Checks are already running for this market; the next one is scheduled.";
    case "NoFundedOrders":
      return "No order in this market has budget left, so there is nothing to restart. Top up an order instead.";
    case "HtsError": {
      const code = Number(args[1]);
      return `Hedera rejected ${HTS_OPERATION[Number(args[0])] ?? "the token operation"}: ${HTS_CODES[code] ?? `response code ${code}`}.`;
    }
  }
  if (name) return `The vault rejected the transaction (${name}).`;
  if (/insufficient (funds|payer balance)/i.test(error.message))
    return "Your account does not have enough HBAR for this transaction and its fee.";
  return error.shortMessage || error.message;
};
