import { connectWallet } from "./support/wallet";
import { type Page, expect, test } from "@playwright/test";
import { type Hex, createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { hederaTestnet } from "viem/chains";

/**
 * The one test that touches the real network: place a DAI stop-loss on the live testnet vault through the UI,
 * let the Hedera Schedule Service fill it, and capture every step at 1440 and 390 in light and dark.
 *
 *   E2E_LIVE_KEY=0x... SCREENSHOTS_DIR=... npx playwright test live --project desktop
 *
 * The key stays in this Node process: the page's wallet forwards eth_sendTransaction to an exposed function
 * that signs with viem. The account needs about 13 HBAR and 0.1 DAI.
 */
const RPC = "https://testnet.hashio.io/api";
const key = process.env.E2E_LIVE_KEY as Hex | undefined;

const capture = async (page: Page, name: string) => {
  const dir = process.env.SCREENSHOTS_DIR;
  if (!dir) return;
  for (const [width, height] of [
    [1440, 1000],
    [390, 900],
  ]) {
    await page.setViewportSize({ width, height });
    await page.evaluate(() => window.scrollTo(0, 0)); // keep the sticky header at the top of a full-page capture
    for (const scheme of ["light", "dark"] as const) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${dir}/${name}-${width}-${scheme}.png`, fullPage: true });
    }
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.emulateMedia({ colorScheme: "light" });
};

test("a stop-loss placed in the UI is filled by the Schedule Service", async ({ page }, info) => {
  test.skip(!key, "set E2E_LIVE_KEY to run against testnet");
  test.skip(info.project.name !== "desktop", "one live order per run");
  test.setTimeout(20 * 60_000);

  const account = privateKeyToAccount(key!);
  const wallet = createWalletClient({ account, chain: hederaTestnet, transport: http(RPC) });
  const reader = createPublicClient({ chain: hederaTestnet, transport: http(RPC) });
  // The relay rejects EIP-1559 fees derived from Hedera's block base fee; sign legacy at its quoted gas price.
  await page.exposeFunction("e2eLiveSend", async (tx: { to: Hex; data?: Hex; value?: Hex; gas?: Hex }) => {
    const gasPrice = await reader.getGasPrice();
    return wallet.sendTransaction({
      to: tx.to,
      data: tx.data,
      value: tx.value ? BigInt(tx.value) : 0n,
      gas: tx.gas ? BigInt(tx.gas) : undefined,
      gasPrice: (gasPrice * 12n) / 10n,
    });
  });
  await page.addInitScript(
    ({ address, rpc }) => {
      const listeners: Record<string, ((value: unknown) => void)[]> = {};
      // Like a real wallet, remember that this site was approved, so reloads stay connected.
      const approved = () => sessionStorage.getItem("e2e-live-approved") === "1";
      let accounts: string[] = approved() ? [address] : [];
      let id = 0;
      const forward = async (method: string, params: unknown[]) => {
        const res = await fetch(rpc, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
        });
        const body = await res.json();
        if (body.error) throw Object.assign(new Error(body.error.message), body.error);
        return body.result;
      };
      (window as unknown as { ethereum: unknown }).ethereum = {
        on: (event: string, listener: (value: unknown) => void) => (listeners[event] ??= []).push(listener),
        removeListener: (event: string, listener: (value: unknown) => void) => {
          listeners[event] = (listeners[event] ?? []).filter(l => l !== listener);
        },
        request: async ({ method, params = [] }: { method: string; params?: unknown[] }) => {
          switch (method) {
            case "eth_requestAccounts":
              accounts = [address];
              sessionStorage.setItem("e2e-live-approved", "1");
              (listeners.accountsChanged ?? []).forEach(l => l(accounts));
              return accounts;
            case "eth_accounts":
              return accounts;
            case "eth_chainId":
              return "0x128";
            case "wallet_requestPermissions":
            case "wallet_revokePermissions":
              return [];
            case "wallet_getPermissions":
              return accounts.length ? [{ parentCapability: "eth_accounts" }] : [];
            case "eth_sendTransaction":
              return (window as unknown as { e2eLiveSend: (tx: unknown) => Promise<string> }).e2eLiveSend(params[0]);
            default:
              return forward(method, params);
          }
        },
      };
    },
    { address: account.address, rpc: RPC },
  );

  await page.goto("/?market=2");
  await connectWallet(page);
  await expect(page.getByTestId("guard-banner")).toContainText("Guard open", { timeout: 60_000 });
  await capture(page, "L1-live-trade");

  await page.getByTestId("kind-stop").click();
  await page.locator("#amount").fill("0.1");
  await page.locator("#trigger").fill("1.0000"); // DAI trades just under 1.0000, so the stop is already met
  await expect(page.getByTestId("budget-line")).toContainText("should fill on the next scheduled check", {
    timeout: 60_000,
  });
  const checklist = page.getByTestId("ticket-checklist");
  const approve = checklist.getByRole("button", { name: "Approve" });
  if (await approve.isVisible()) {
    await approve.click();
    await expect(page.getByTestId("tx-status")).toContainText("Done.", { timeout: 120_000 });
  }
  await capture(page, "L2-live-ticket");

  await expect(page.getByTestId("place-order")).toBeEnabled({ timeout: 60_000 });
  await page.getByTestId("place-order").click();
  await expect(page.getByTestId("placed")).toContainText(/Order #\d+ placed/, { timeout: 180_000 });
  await capture(page, "L3-live-order-placed");

  await page.getByRole("link", { name: "Follow it" }).click();
  await expect(page.getByRole("heading", { name: /Order #\d+/ })).toBeVisible({ timeout: 60_000 });
  await expect(page.getByTestId("trail")).toContainText("Placed: 0.1 DAI escrowed", { timeout: 120_000 });
  await capture(page, "L4-live-order-waiting");

  // The market's next scheduled sweep is at most minInterval (5 min) away; allow for mirror-node lag.
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("trail")).toContainText("Filled:", { timeout: 10_000 });
  }).toPass({ timeout: 15 * 60_000, intervals: [30_000] });
  await capture(page, "L5-live-order-filled");

  // Navigate in-app: a full reload would drop this test wallet's connection, which a real wallet remembers.
  await page.getByRole("link", { name: "My orders" }).first().click();
  await expect(page.getByTestId("orders-summary")).toBeVisible({ timeout: 60_000 });
  await capture(page, "L6-live-my-orders");
});
