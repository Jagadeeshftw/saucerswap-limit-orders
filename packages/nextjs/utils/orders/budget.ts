/**
 * Check-budget arithmetic for the order ticket. The vault supplies every price (solo check, reserve, minimum
 * budget) and the wait between checks; this module only combines them.
 */

/** Checks an order needs over `lifetime` seconds if the price stays where it is now: one per wait. */
export const checksFor = (lifetime: number, wait: number) => Math.max(1, Math.ceil(lifetime / Math.max(1, wait)));

/** Budget that pays for `checks` solo checks on top of the reserve, and never less than the vault's minimum. */
export const budgetFor = (checks: number, soloCheck: bigint, reserve: bigint, minBudget: bigint) => {
  const covering = reserve + BigInt(checks) * soloCheck;
  return covering > minBudget ? covering : minBudget;
};

/** How long `budget` keeps an order checked at `perCheck` HBAR every `wait` seconds, after the reserve. */
export const coverageSeconds = (budget: bigint, reserve: bigint, perCheck: bigint, wait: number) =>
  budget <= reserve || perCheck === 0n ? 0 : Number((budget - reserve) / perCheck) * wait;

export const durationText = (seconds: number) =>
  seconds >= 86_400
    ? `${Math.floor(seconds / 86_400)} d`
    : seconds >= 3600
      ? `${Math.floor(seconds / 3600)} h`
      : `${Math.max(1, Math.floor(seconds / 60))} min`;
