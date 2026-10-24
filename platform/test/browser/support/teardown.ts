import {existsSync, readFileSync} from "node:fs"

// The end of every walk whose server started, passed or failed: each request the
// walk's server refused outside this machine, written to this file by
// Autolaunch.WalkOffline, fails the walk, whichever page caused it. The run's
// database is dropped by test/browser/walk.sh.
export default function teardown() {
  const file = "tmp/walk-outside.txt"
  const outside = existsSync(file) ? readFileSync(file, "utf8").trim() : ""
  if (outside !== "")
    throw new Error(`The walk's server made requests outside this machine:\n${outside}`)
}
