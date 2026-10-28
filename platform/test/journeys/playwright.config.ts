import {defineConfig, devices} from "@playwright/test"

// The agent journeys (scripts/agent-journeys.sh), against the stack that script
// starts: Autolaunch on its own database, its own sign-in service, a copy of Base
// and the regents command line. Each journey plays both sides: the regents binary
// is the agent, and the browser is its person, on a touch phone at 390 wide and a
// desktop at 1280. One at a time, because the people and the chain are shared.
const out = process.env.AGENT_JOURNEYS_OUT!

export default defineConfig({
  testDir: ".",
  testMatch: /\.spec\.ts$/,
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  timeout: 600_000,
  expect: {timeout: 15_000},
  outputDir: `${out}/playwright`,
  reporter: [["line"], ["json", {outputFile: `${out}/journeys.json`}]],
  use: {
    baseURL: process.env.AUTOLAUNCH_URL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {name: "phone", use: {...devices["Pixel 7"], viewport: {width: 390, height: 844}}},
    {name: "desktop", use: {...devices["Desktop Chrome"], viewport: {width: 1280, height: 900}}},
  ],
})
