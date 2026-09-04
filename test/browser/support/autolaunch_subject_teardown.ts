import {execFileSync} from "node:child_process"

// The browser proof and `mix test` share one local test database, and the
// configured web server seeds a public Autolaunch subject before the first test.
// One left behind would change what the ordinary suite sees listed, so the run
// takes it away again, whichever specs the run happened to select.
export default function removeBrowserAutolaunchSubject(): void {
  execFileSync("mix", ["autolaunch.seed_browser_subject", "--remove"], {
    env: {...process.env, MIX_ENV: "test"},
    stdio: "inherit",
  })
}
