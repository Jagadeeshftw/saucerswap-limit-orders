/**
 * Check-budget arithmetic for the order ticket. The vault supplies every price (solo check, reserve, minimum
 * budget) and the wait between checks; this module only combines them.
 */

/** Checks an order needs over `lifetime` seconds if the price stays where it is now: one per wait. */
export const checksFor = (lifetime: number, wait: number) => Math.max(1, Math.ceil(lifetime / Math.max(1, wait)));

/**
 * Checks a triggered order gets while the guard holds it: the vault retries after minInterval, then doubles the
 * wait (minInterval x 2^streak, streak capped at 8) up to maxInterval, until `lifetime` runs out.
 */
export const checksWhileHeld = (lifetime: number, minInterval: number, maxInterval: number) => {
  let checks = 1;
  let at = minInterval;
  for (let streak = 1; ; streak++) {
    const wait = Math.min(minInterval * 2 ** Math.min(streak, 8), maxInterval);
    if (at + wait > lifetime) return checks;
    at += wait;
    checks++;
  }
};

/** Budget that pays for `checks` solo checks on top of the reserve, and never less than the vault's minimum. */
export const budgetFor = (checks: number, soloCheck: bigint, reserve: bigint, minBudget: bigint) => {
  const covering = reserve + BigInt(checks) * soloCheck;
  return covering > minBudget ? covering : minBudget;
};

/** How long `budget` keeps an order checked at `perCheck` HBAR every `wait` seconds, after the reserve. */
export const coverageSeconds = (budget: bigint, reserve: bigint, perCheck: bigint, wait: number) =>
  budget <= reserve || perCheck === 0n ? 0 : Number((budget - reserve) / perCheck) * wait;

/** A duration rounded to its largest unit, for "about every 2 h" style copy. */
export const durationText = (seconds: number) =>
  seconds >= 86_400
    ? `${Math.round(seconds / 86_400)} d`
    : seconds >= 3600
      ? `${Math.round(seconds / 3600)} h`
      : `${Math.max(1, Math.round(seconds / 60))} min`;
