import {spawnSync} from "node:child_process"
import {readFileSync, writeFileSync} from "node:fs"
import {expect} from "@playwright/test"

/**
 * Runs one of test/journeys/support's scripts with the journey site's own
 * settings, on its database and its copy of Base, and answers what it printed.
 */
export function onSite(script: string, env: Record<string, string>): string {
  const site = readFileSync(`${process.env.STACK_STATE}/site.env`, "utf8").trim().split("\n")
  const settings = Object.fromEntries(site.map(line => line.split(/=(.*)/s).slice(0, 2)))
  const run = spawnSync("mix", ["run", "--no-start", `test/journeys/support/${script}`], {
    encoding: "utf8",
    env: {...process.env, ...settings, ...env},
  })
  writeFileSync(`${process.env.AGENT_JOURNEYS_OUT}/site-scripts.log`, `== ${script}\n${run.stdout}${run.stderr}`, {flag: "a"})
  expect(run.status, run.stderr).toBe(0)
  return run.stdout
}
