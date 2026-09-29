import { defineConfig } from "@playwright/test";

const port = 3210;

/**
 * End-to-end tests run against a production build with the Hedera JSON-RPC relay, mirror node and wallet mocked
 * in the browser (see e2e/support), so every state is reproducible without keys or testnet funds.
 * Set E2E_BASE_URL to reuse a server that is already running.
 */
export default defineConfig({
  testDir: "e2e",
  timeout: 60_000,
  expect: { timeout: 15_000 },
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: process.env.E2E_BASE_URL ?? `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
  },
  projects: [
    { name: "desktop", use: { viewport: { width: 1440, height: 1000 } } },
    { name: "mobile", use: { viewport: { width: 390, height: 900 }, isMobile: true, hasTouch: true } },
  ],
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: `npx next build && npx next start -p ${port}`,
        url: `http://127.0.0.1:${port}`,
        timeout: 300_000,
        reuseExistingServer: !process.env.CI,
      },
});
