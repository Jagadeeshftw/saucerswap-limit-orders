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

/** How many checks `budget` pays for at `perCheck` each, after holding back `reserve` for the fill. */
export const checksAffordable = (budget: bigint, reserve: bigint, perCheck: bigint) =>
  budget <= reserve || perCheck === 0n ? 0 : Number((budget - reserve) / perCheck);

/**
 * When the last of `checks` checks runs while the guard holds a triggered order: the first after minInterval,
 * then the vault's doubling back-off (the same schedule as checksWhileHeld).
 */
export const heldSeconds = (checks: number, minInterval: number, maxInterval: number) => {
  if (checks < 1) return 0;
  let at = minInterval;
  for (let streak = 1; streak < checks; streak++) at += Math.min(minInterval * 2 ** Math.min(streak, 8), maxInterval);
  return at;
};

/** A duration in words for "covers ~6 days" style copy: days from a day up, then hours, then minutes. */
export const durationWords = (seconds: number) => {
  const plural = (n: number, unit: string) => `${n} ${unit}${n === 1 ? "" : "s"}`;
  if (seconds >= 86_400) return plural(Math.floor(seconds / 86_400), "day");
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)} h`;
  return `${Math.max(1, Math.floor(seconds / 60))} min`;
};
