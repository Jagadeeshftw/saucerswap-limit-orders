import { ACCOUNT } from "./scenario";
import { type Page, expect } from "@playwright/test";

/**
 * A browser wallet (EIP-1193 on window.ethereum) injected before the app loads. It holds one account, reports whichever
 * chain the test asks for, and forwards everything else to the (mocked) Hedera JSON-RPC relay, which is where
 * eth_sendTransaction lands. No keys, no signing.
 */
export const injectWallet = async (page: Page, chainId: number) => {
  await page.addInitScript(
    ({ account, startChainId }) => {
      const listeners: Record<string, ((...args: unknown[]) => void)[]> = {};
      const emit = (event: string, value: unknown) => (listeners[event] ?? []).forEach(l => l(value));
      let chain = startChainId;
      let accounts: string[] = [];
      let id = 0;
      const forward = async (method: string, params: unknown[]) => {
        const res = await fetch("https://testnet.hashio.io/api", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
        });
        const body = await res.json();
        if (body.error) throw Object.assign(new Error(body.error.message), body.error);
        return body.result;
      };
      const provider = {
        on: (event: string, listener: (...args: unknown[]) => void) => {
          (listeners[event] ??= []).push(listener);
        },
        removeListener: (event: string, listener: (...args: unknown[]) => void) => {
          listeners[event] = (listeners[event] ?? []).filter(l => l !== listener);
        },
        request: async ({ method, params = [] }: { method: string; params?: unknown[] }) => {
          switch (method) {
            case "eth_requestAccounts":
              accounts = [account];
              emit("accountsChanged", accounts);
              return accounts;
            case "eth_accounts":
              return accounts;
            case "eth_chainId":
              return `0x${chain.toString(16)}`;
            case "net_version":
              return String(chain);
            case "wallet_switchEthereumChain":
              chain = parseInt((params[0] as { chainId: string }).chainId, 16);
              emit("chainChanged", `0x${chain.toString(16)}`);
              return null;
            case "wallet_requestPermissions":
            case "wallet_revokePermissions":
              return [];
            case "wallet_getPermissions":
              return accounts.length ? [{ parentCapability: "eth_accounts" }] : [];
            default:
              return forward(method, params);
          }
        },
      };
      (window as unknown as { ethereum: unknown }).ethereum = provider;
      // Lets a test change network the way a user does in their wallet after connecting.
      (window as unknown as { e2eWallet: unknown }).e2eWallet = {
        setChain: (next: number) => {
          chain = next;
          emit("chainChanged", `0x${next.toString(16)}`);
        },
      };
    },
    { account: ACCOUNT, startChainId: chainId },
  );
};

/** Change the wallet's network after connecting, as a user would in their wallet. */
export const switchWalletChain = (page: Page, chainId: number) =>
  page.evaluate(
    id => (window as unknown as { e2eWallet: { setChain: (n: number) => void } }).e2eWallet.setChain(id),
    chainId,
  );

/** Connect through RainbowKit's modal the way a user would, choosing "Browser Wallet". */
export const connectWallet = async (page: Page) => {
  // Retry until hydration has attached RainbowKit's handler and the modal opens.
  await expect(async () => {
    await page
      .getByRole("button", { name: /connect wallet/i })
      .first()
      .click();
    await expect(page.getByRole("button", { name: /browser wallet/i })).toBeVisible({ timeout: 1_000 });
  }).toPass({ timeout: 20_000 });
  await page.getByRole("button", { name: /browser wallet/i }).click();
  await expect(page.getByTestId("network-pill")).toBeVisible();
  await expect(page.getByRole("button", { name: /connect wallet/i })).toHaveCount(0, { timeout: 10_000 });
};
