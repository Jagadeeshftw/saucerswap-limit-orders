import { mockNetwork } from "./support/mockNetwork";
import { DAI, type Scenario, baseScenario, withOrderBook } from "./support/scenario";
import { connectWallet, injectWallet, switchWalletChain } from "./support/wallet";
import { type Page, type TestInfo, expect, test } from "@playwright/test";

/** With SCREENSHOTS_DIR set, every state is captured in light and dark at the project's width. */
const capture = async (page: Page, info: TestInfo, state: string) => {
  const dir = process.env.SCREENSHOTS_DIR;
  if (!dir) return;
  const width = info.project.name === "mobile" ? 390 : 1440;
  for (const scheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${dir}/${state}-${width}-${scheme}.png`, fullPage: true });
  }
  await page.emulateMedia({ colorScheme: "light" });
};

const open = async (page: Page, s: Scenario, path: string, { connect = true } = {}) => {
  await injectWallet(page, s.walletChainId);
  await mockNetwork(page, s);
  await page.goto(path);
  if (connect) await connectWallet(page);
};

const fillTicket = async (page: Page, amount: string, trigger?: string) => {
  await page.locator("#amount").fill(amount);
  if (trigger) await page.locator("#trigger").fill(trigger);
};

test.describe("Trade", () => {
  test("shows public market data and a connect prompt before a wallet is connected", async ({ page }, info) => {
    await open(page, baseScenario(), "/", { connect: false });
    await expect(page.getByTestId("guard-banner")).toContainText("Guard closed");
    await expect(page.getByText("185,058 bps")).toBeVisible();
    await expect(page.getByRole("button", { name: /connect wallet/i }).last()).toBeVisible();
    await capture(page, info, "01-trade-disconnected");
  });

  test("describes a limit sell and enables placing it when the guard is open", async ({ page }, info) => {
    await open(page, baseScenario(), "/?market=2");
    await expect(page.getByTestId("guard-banner")).toContainText("Guard open");
    await fillTicket(page, "1000", "1.0100");
    await expect(page.getByTestId("ticket-summary")).toContainText(
      "Sells 1,000 DAI when Chainlink shows DAI at or above 1.0100 USDC",
    );
    await expect(page.getByTestId("ticket-summary")).toContainText("You receive at least 1,004.95 USDC");
    await expect(page.getByTestId("budget-line")).toContainText("1.8977 HBAR per check");
    await capture(page, info, "02-trade-guard-open");
  });

  test("closes the guard when a Chainlink feed is stale", async ({ page }, info) => {
    const s = baseScenario();
    s.guards[1] = {
      ...s.guards[1],
      state: 2,
      deviationBps: 0n,
      poolPrice: 0n,
      oracleUpdatedAt: BigInt(Math.floor(Date.now() / 1000) - 100_000),
    };
    await open(page, s, "/");
    await expect(page.getByTestId("guard-banner")).toContainText("Guard closed");
    await expect(page.getByTestId("guard-banner")).toContainText("has not updated within the allowed age");
    await capture(page, info, "03-trade-oracle-stale");
  });

  test("closes the guard when the pool deviates from Chainlink", async ({ page }, info) => {
    await open(page, baseScenario(), "/");
    await expect(page.getByTestId("guard-banner")).toContainText("The pool is too far from Chainlink");
    await capture(page, info, "04-trade-guard-deviation");
  });

  test("uses unambiguous copy on the buy side", async ({ page }, info) => {
    await open(page, baseScenario(), "/");
    await page.getByTestId("side-buy").click();
    await expect(page.getByTestId("kind-limit")).toHaveText("Limit buy");
    await expect(page.getByText("Buy HBAR when price is at or below")).toBeVisible();
    await fillTicket(page, "50", "0.0950");
    await expect(page.getByTestId("ticket-summary")).toContainText("You receive at least 523.6842 HBAR");
    await capture(page, info, "05-trade-limit-buy");
    await page.getByTestId("kind-stop").click();
    await expect(page.getByTestId("kind-stop")).toHaveText("Stop-buy");
    await expect(page.getByText("Buy HBAR when price is at or above")).toBeVisible();
    await expect(page.getByTestId("ticket-summary")).toContainText("a stop can fill past it");
    await capture(page, info, "06-trade-stop-buy");
  });

  test("blocks an order the wallet cannot pay for", async ({ page }, info) => {
    const s = baseScenario();
    s.hbarTinybar = 5_00_000_000n;
    await open(page, s, "/");
    await fillTicket(page, "250", "0.1100");
    await expect(page.getByTestId("ticket-problem").first()).toContainText("Insufficient HBAR");
    await expect(page.getByTestId("place-order")).toBeDisabled();
    await capture(page, info, "07-trade-insufficient-balance");
  });

  test("asks to switch networks, on every width", async ({ page }, info) => {
    await open(page, baseScenario(), "/");
    await switchWalletChain(page, 1);
    await expect(page.getByTestId("wrong-network")).toBeVisible();
    await expect(page.getByTestId("network-pill")).toContainText("Wrong network");
    await capture(page, info, "08-wrong-network");
    await page.getByRole("button", { name: "Switch to Hedera Testnet" }).click();
    await expect(page.getByTestId("wrong-network")).toHaveCount(0);
  });

  test("walks through association and approval before a token order", async ({ page }, info) => {
    const s = baseScenario();
    s.mirrorAccount = { id: s.mirrorAccount!.id, maxAutoAssociations: 0 };
    await open(page, s, "/?market=2");
    await fillTicket(page, "100", "0.9950");
    await page.getByTestId("kind-stop").click();
    const checklist = page.getByTestId("ticket-checklist");
    await expect(checklist).toContainText("Associate the order NFT collection");
    await expect(checklist).toContainText("Associate USDC");
    await expect(checklist).toContainText("Let the vault take 100 DAI");
    await expect(page.getByTestId("place-order")).toBeDisabled();
    await capture(page, info, "09-trade-setup-steps");
    for (const name of ["Associate", "Associate", "Approve"]) {
      await checklist.getByRole("button", { name }).first().click();
      await expect(page.getByTestId("tx-status")).toContainText("Done.");
    }
    await expect(page.getByTestId("place-order")).toBeEnabled();
    expect(s.tokens[DAI].allowance).toBe(100_00_000_000n);
  });

  test("explains a Hedera address with no account yet", async ({ page }, info) => {
    const s = baseScenario();
    s.mirrorAccount = null;
    await open(page, s, "/");
    await expect(page.getByTestId("ticket-checklist")).toContainText("has no Hedera testnet account yet");
    await capture(page, info, "10-trade-no-account");
  });

  test("shows the pending states while a transaction confirms", async ({ page }, info) => {
    const s = baseScenario();
    s.send = { kind: "success", confirmAfterPolls: 10_000 };
    s.tokens[DAI].allowance = 10n ** 20n;
    await open(page, s, "/?market=2");
    await fillTicket(page, "100", "1.0100");
    await page.getByTestId("place-order").click();
    await expect(page.getByTestId("tx-status")).toContainText("Waiting for Hedera consensus");
    await expect(page.getByTestId("place-order")).toHaveText("Placing order");
    await capture(page, info, "11-tx-confirming");
  });

  test("explains a failed transaction in plain words", async ({ page }, info) => {
    const s = baseScenario();
    s.send = { kind: "revert", errorName: "InsufficientBudget", args: [1n, 1_207_713_381n] };
    await open(page, s, "/");
    await fillTicket(page, "20", "0.1100");
    await page.getByTestId("place-order").click();
    await expect(page.getByTestId("tx-error")).toContainText(
      "The check budget is too small: send at least 12.0771 HBAR.",
    );
    await capture(page, info, "12-tx-failed");
  });

  test("places an order and links to it", async ({ page }, info) => {
    const s = baseScenario();
    await open(page, s, "/");
    await fillTicket(page, "20", "0.1100");
    await page.getByTestId("place-order").click();
    await expect(page.getByTestId("placed")).toContainText("Order #21 placed.");
    await capture(page, info, "13-order-placed");
    expect(s.sent.at(-1)?.value).toBeDefined();
    await page.getByRole("link", { name: "Follow it" }).click();
    await expect(page.getByRole("heading", { name: "Order #21" })).toBeVisible();
  });
});

test.describe("My orders", () => {
  test("lists every order newest first with consistent open counts", async ({ page }, info) => {
    await open(page, withOrderBook(baseScenario()), "/orders");
    await expect(page.getByTestId("orders-summary")).toHaveText("7 orders · 5 open");
    await expect(page.getByTestId("filter-open")).toHaveText("Open 5");
    const rows = page.getByTestId(info.project.name === "mobile" ? "order-card" : "order-row");
    await expect(rows).toHaveCount(7);
    await expect(rows.first()).toContainText("#14");
    await expect(rows.nth(1)).toContainText("#13");
    await expect(rows.nth(1)).toContainText("Held by guard");
    await expect(rows.nth(3)).toContainText("Budget empty");
    await expect(rows.last()).toContainText("#1");
    await capture(page, info, "14-my-orders");
    await page.getByTestId("filter-open").click();
    await expect(rows).toHaveCount(5);
  });

  test("has a designed empty state", async ({ page }, info) => {
    await open(page, baseScenario(), "/orders");
    await expect(page.getByTestId("orders-empty")).toContainText("No orders yet");
    await capture(page, info, "15-my-orders-empty");
  });

  test("warns when the mirror node is behind", async ({ page }, info) => {
    const s = withOrderBook(baseScenario());
    s.mirrorLagSeconds = 45;
    await open(page, s, "/orders");
    await expect(page.getByTestId("mirror-lag")).toContainText(/Status may be up to 4\d s behind/);
    await capture(page, info, "16-mirror-lag");
  });
});

test.describe("Order detail", () => {
  test("shows the Schedule Service checks of an order held by the guard", async ({ page }, info) => {
    await open(page, withOrderBook(baseScenario()), "/orders/2");
    await expect(page.getByRole("heading", { name: "Order #2" })).toBeVisible();
    const trail = page.getByTestId("trail");
    await expect(trail).toContainText("held by guard");
    await expect(trail).toContainText("Placed: 20 HBAR escrowed");
    await expect(trail.getByRole("link", { name: "HashScan" }).first()).toHaveAttribute(
      "href",
      /hashscan\.io\/testnet\/transaction\/\d+\.\d+/,
    );
    await capture(page, info, "17-order-held");
  });

  test("shows a filled order", async ({ page }, info) => {
    await open(page, withOrderBook(baseScenario()), "/orders/1");
    await expect(page.getByTestId("trail")).toContainText("Filled: 3 DAI for 3.0052 USDC");
    await expect(page.getByTestId("order-actions")).toHaveCount(0);
    await capture(page, info, "18-order-filled");
  });
});

test("the mobile menu opens the navigation", async ({ page }, info) => {
  test.skip(info.project.name !== "mobile", "the burger only exists on small screens");
  await open(page, baseScenario(), "/", { connect: false });
  await page.getByTestId("burger").click();
  const menu = page.locator("details[open] ul");
  for (const label of ["Trade", "My orders", "Debug Contracts", "Block Explorer"]) {
    await expect(menu.getByRole("link", { name: label })).toBeVisible();
  }
  await capture(page, info, "19-mobile-menu");
  await menu.getByRole("link", { name: "My orders" }).click();
  await expect(page).toHaveURL(/\/orders$/);
});
