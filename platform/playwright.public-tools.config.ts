import {defineConfig} from "@playwright/test"

const port = process.env.PORT
if (!port || !/^\d+$/.test(port)) throw new Error("Run public-tool QA through the prepared worktree environment")
const baseURL = `http://127.0.0.1:${port}`

export default defineConfig({
  testDir: "./test/browser",
  testMatch: "public_tools.spec.ts",
  workers: 1,
  retries: 0,
  reporter: "line",
  use: {baseURL, trace: "retain-on-failure"},
  outputDir: "./test-results/public-tools",
  webServer: {
    command: "mix run --no-start test/browser/support/seed_public_tools.exs && AUTOLAUNCH_BROWSER_TEST=1 mix run --no-halt",
    url: `${baseURL}/healthz`,
    reuseExistingServer: false,
    timeout: 120_000,
  },
})
