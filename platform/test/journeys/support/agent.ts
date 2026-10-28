import {spawnSync} from "node:child_process"
import {chmodSync, mkdirSync, mkdtempSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {generatePrivateKey, privateKeyToAccount} from "viem/accounts"

// One agent: the regents binary, run as a subprocess against this stack, with a
// key folder of its own. Its key is written the way the SIWA agent client's keygen
// writes one, a plain key in key.json, because the regents keygen on a Mac locks
// the key with Touch ID, which no headless run can press.
export type Answer = {status: number; json: any; stdout: string; stderr: string}

export class Agent {
  readonly home: string
  readonly address: string
  readonly privateKey: `0x${string}`

  constructor(readonly label: string) {
    mkdirSync(`${process.env.AGENT_JOURNEYS_OUT}/agents`, {recursive: true})
    this.home = mkdtempSync(join(`${process.env.AGENT_JOURNEYS_OUT}/agents`, `${label}-`))
    chmodSync(this.home, 0o700)
    this.privateKey = generatePrivateKey()
    this.address = privateKeyToAccount(this.privateKey).address.toLowerCase()
    writeFileSync(
      join(this.home, "key.json"),
      JSON.stringify({address: this.address, private_key: this.privateKey}),
      {mode: 0o600},
    )
  }

  /** Runs `regents <args> --json`, with `stdin` as JSON when given. */
  run(args: string[], stdin?: unknown): Answer {
    const result = spawnSync(process.env.REGENTS!, [...args, "--json"], {
      input: stdin === undefined ? "" : JSON.stringify(stdin),
      encoding: "utf8",
      env: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        SIWA_AGENT_HOME: this.home,
        SIWA_BROKER: process.env.SIWA_URL,
        AUTOLAUNCH_BASE_URL: process.env.AUTOLAUNCH_URL,
        PYTHON_GIL: "0",
      },
      timeout: 60_000,
    })
    let json: any = null
    try {
      json = JSON.parse(result.stdout)
    } catch {
      json = null
    }
    return {status: result.status ?? -1, json, stdout: result.stdout, stderr: result.stderr}
  }

  /** `regents autolaunch <args>`. */
  autolaunch(args: string[], stdin?: unknown): Answer {
    return this.run(["autolaunch", ...args], stdin)
  }

  signIn(): Answer {
    return this.run(["auth", "login", "--site", "autolaunch"])
  }
}
