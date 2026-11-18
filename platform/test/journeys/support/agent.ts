import {spawn, spawnSync} from "node:child_process"
import {chmodSync, mkdirSync, mkdtempSync, writeFileSync} from "node:fs"
import {dirname, join} from "node:path"
import {createInterface} from "node:readline"
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
      env: this.env(),
      timeout: 60_000,
    })
    return {status: result.status ?? -1, json: parsed(result.stdout), stdout: result.stdout, stderr: result.stderr}
  }

  private env() {
    return {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      SIWA_AGENT_HOME: this.home,
      SIWA_BROKER: process.env.SIWA_URL,
      AUTOLAUNCH_BASE_URL: process.env.AUTOLAUNCH_URL,
      // The site's throwaway certificate (scripts/agent-journeys.sh).
      SSL_CERT_FILE: process.env.SITE_CERT,
    }
  }

  /** `regents autolaunch <args>`, without waiting: several can run at once. */
  autolaunchAtOnce(args: string[], stdin?: unknown): Promise<Answer> {
    return new Promise(resolve => {
      const child = spawn(process.env.REGENTS!, ["autolaunch", ...args, "--json"], {env: this.env()})
      let stdout = ""
      let stderr = ""
      child.stdout.on("data", chunk => (stdout += chunk))
      child.stderr.on("data", chunk => (stderr += chunk))
      child.on("close", status => resolve({status: status ?? -1, json: parsed(stdout), stdout, stderr}))
      child.stdin.end(stdin === undefined ? "" : JSON.stringify(stdin))
    })
  }

  /** `regents autolaunch <args>`. */
  autolaunch(args: string[], stdin?: unknown): Answer {
    return this.run(["autolaunch", ...args], stdin)
  }

  signIn(): Answer {
    return this.run(["auth", "login", "--site", "autolaunch"])
  }

  /**
   * One request to the site's signed agent routes, signed and sent by the regents command line's
   * own signer and sender with this agent's key (support/signed.py): for a route the command
   * line has no command for yet. Answers the status and the JSON body.
   */
  signed(method: string, path: string, body?: unknown): {status: number; json: any} {
    const result = spawnSync(
      join(dirname(process.env.REGENTS!), "python"),
      ["-I", "test/journeys/support/signed.py", method, path],
      {input: body === undefined ? "" : JSON.stringify(body), encoding: "utf8", env: this.env(), timeout: 60_000},
    )
    if (result.status !== 0) throw new Error(`signed ${method} ${path} failed: ${result.stderr}`)
    return JSON.parse(result.stdout)
  }

  /**
   * Calls the site's hosted MCP tools through `regents mcp --site autolaunch`, as an agent host
   * runs it: one session that initializes, then makes each call in turn. Answers each call's
   * result: the tool's answer under `structuredContent`, or its refusal with `isError`.
   */
  async mcp(calls: {name: string; input: unknown}[]): Promise<any[]> {
    const child = spawn(process.env.REGENTS!, ["mcp", "--site", "autolaunch"], {env: this.env()})
    let stderr = ""
    child.stderr.on("data", chunk => (stderr += chunk))
    const waiting = new Map<number, (message: any) => void>()
    createInterface({input: child.stdout}).on("line", line => {
      const message = JSON.parse(line)
      waiting.get(message.id)?.(message)
    })
    const send = (message: object) => child.stdin.write(JSON.stringify({jsonrpc: "2.0", ...message}) + "\n")
    const ask = (id: number, method: string, params: object) =>
      new Promise<any>((resolve, reject) => {
        const late = setTimeout(() => reject(new Error(`regents mcp did not answer ${method}: ${stderr}`)), 60_000)
        waiting.set(id, message => {
          clearTimeout(late)
          if (message.error) reject(new Error(`regents mcp ${method}: ${JSON.stringify(message.error)}`))
          else resolve(message.result)
        })
        send({id, method, params})
      })

    try {
      await ask(0, "initialize", {
        protocolVersion: "2025-11-25",
        capabilities: {},
        clientInfo: {name: "agent-journeys", version: "1"},
      })
      send({method: "notifications/initialized"})
      const results = []
      for (const [index, {name, input}] of calls.entries()) {
        results.push(await ask(index + 1, "tools/call", {name, arguments: {input}}))
      }
      return results
    } finally {
      const closed = new Promise(resolve => child.on("close", resolve))
      child.stdin.end()
      await closed
    }
  }
}

function parsed(stdout: string): any {
  try {
    return JSON.parse(stdout)
  } catch {
    return null
  }
}
