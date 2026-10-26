import {defineConfig, devices} from "@playwright/test"

// The browser walk (make check-browser), started by test/browser/walk.sh, which
// takes the run's port, makes the run's database and drops it at the end. Here it
// builds the pages' scripts and styles, starts the site's browser test server on
// that database, and signs its person in first (test/browser/sign_in.setup.ts). It
// walks a desktop at 1280 wide and a touch phone at 390 wide. Chromium only: WebKit
// is not run on the Mac.
// Neither the browser nor the server leaves this machine: the browser's outside
// requests fail the check that made them (test/browser/support/test.ts), and the
// server, with the outside services' settings cleared, refuses its own and the walk
// fails at the end (config/test.exs, test/browser/support/teardown.ts).
// Each run's port and database are its own, so two walks at once, from two
// checkouts, never reach each other's server or data.
const port = Number(process.env.AUTOLAUNCH_WALK_PORT)
const baseURL = `http://127.0.0.1:${port}`

export default defineConfig({
  testDir: "./test/browser",
  fullyParallel: true,
  workers: 3,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  globalTeardown: "./test/browser/support/teardown.ts",
  use: {
    baseURL,
    trace: "retain-on-failure",
  },
  webServer: {
    command:
      "mkdir -p tmp && rm -f tmp/walk-outside.txt tmp/walk-lines.jsonl && " +
      "unset ETHEREUM_READ_RPC_URL BASE_READ_RPC_URL AUTOLAUNCH_BASE_DEPLOYMENT AUTOLAUNCH_LAB_AUTH " +
      "X_OAUTH_CLIENT_ID DATABASE_URL DATABASE_DIRECT_URL && " +
      `export AUTOLAUNCH_WALK=true AUTOLAUNCH_BROWSER_TEST=1 PORT=${port} AUTOLAUNCH_DB_POOL_SIZE=3 ` +
      "PRIVY_APP_ID=autolaunch-fixture && " +
      "mix assets.build && mix phx.server",
    url: `${baseURL}/healthz`,
    reuseExistingServer: false,
    timeout: 180_000,
  },
  projects: [
    {name: "sign-in", testMatch: /sign_in\.setup\.ts/},
    {
      name: "desktop",
      dependencies: ["sign-in"],
      use: {...devices["Desktop Chrome"], viewport: {width: 1280, height: 900}},
    },
    {
      name: "phone",
      dependencies: ["sign-in"],
      use: {...devices["Pixel 7"], viewport: {width: 390, height: 844}},
    },
  ],
})
