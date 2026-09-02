import {defineConfig, devices} from "@playwright/test"

export default defineConfig({
  testDir: "./test/browser",
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: "line",
  use: {
    baseURL: "http://127.0.0.1:4050",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "MIX_ENV=test AUTOLAUNCH_BROWSER_TEST=1 mix phx.server",
    url: "http://127.0.0.1:4050/healthz",
    reuseExistingServer: false,
    timeout: 120_000,
  },
  projects: [
    {
      name: "chromium",
      use: {...devices["Desktop Chrome"]},
    },
  ],
})
