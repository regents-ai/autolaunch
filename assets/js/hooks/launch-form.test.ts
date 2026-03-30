import assert from "node:assert/strict"
import { afterEach, beforeEach, describe, it } from "node:test"

import {
  buildLaunchRequestBody,
  buildSiwaMessage,
  LaunchForm,
  launchEndpoints,
  parseLaunchChainId,
  readForm,
} from "./launch-form.ts"

class FakeInputElement {
  name: string
  value: string
  type: string
  checked: boolean

  constructor(name: string, value: string, type = "text", checked = false) {
    this.name = name
    this.value = value
    this.type = type
    this.checked = checked
  }
}

class FakeTextAreaElement {
  name: string
  value: string

  constructor(name: string, value: string) {
    this.name = name
    this.value = value
  }
}

class FakeButton {
  dataset: Record<string, string>
  disabled = false
  private clickHandlers = new Set<() => Promise<void> | void>()

  constructor(dataset: Record<string, string>) {
    this.dataset = dataset
  }

  addEventListener(eventName: string, handler: () => Promise<void> | void) {
    if (eventName === "click") this.clickHandlers.add(handler)
  }

  removeEventListener(eventName: string, handler: () => Promise<void> | void) {
    if (eventName === "click") this.clickHandlers.delete(handler)
  }

  hasAttribute(name: string): boolean {
    return name === "disabled" ? this.disabled : false
  }

  async click() {
    for (const handler of this.clickHandlers) {
      await handler()
    }
  }
}

class FakeRoot {
  private button: FakeButton
  private fields: Array<FakeInputElement | FakeTextAreaElement>

  constructor(button: FakeButton, fields: Array<FakeInputElement | FakeTextAreaElement> = []) {
    this.button = button
    this.fields = fields
  }

  querySelector(selector: string) {
    if (selector === "[data-launch-submit]") return this.button
    return null
  }

  querySelectorAll(_selector: string) {
    return this.fields
  }
}

type FetchCall = { url: string | URL | Request; init?: RequestInit }

const originalWindow = globalThis.window
const originalDocument = globalThis.document
const originalFetch = globalThis.fetch
const originalInput = globalThis.HTMLInputElement
const originalTextarea = globalThis.HTMLTextAreaElement

function installDomGlobals() {
  globalThis.HTMLInputElement = FakeInputElement as unknown as typeof HTMLInputElement
  globalThis.HTMLTextAreaElement = FakeTextAreaElement as unknown as typeof HTMLTextAreaElement
  globalThis.document = {
    querySelector(selector: string) {
      if (selector === "meta[name='csrf-token']") {
        return { content: "csrf-123" }
      }

      return null
    },
  } as Document
}

function restoreGlobals() {
  globalThis.window = originalWindow
  globalThis.document = originalDocument
  globalThis.fetch = originalFetch
  globalThis.HTMLInputElement = originalInput
  globalThis.HTMLTextAreaElement = originalTextarea
}

function hookContext(button: FakeButton, fields: Array<FakeInputElement | FakeTextAreaElement> = []) {
  const pushed: Array<{ name: string; payload: unknown }> = []

  const context = {
    el: new FakeRoot(button, fields),
    pushEvent(name: string, payload: unknown) {
      pushed.push({ name, payload })
    },
  }

  return { context, pushed }
}

function mountLaunchForm(context: { el: FakeRoot; pushEvent(name: string, payload: unknown): void }) {
  const mounted = LaunchForm.mounted
  assert.ok(mounted, "LaunchForm.mounted must exist")
  mounted.call(context as never)
}

function destroyLaunchForm(context: { el: FakeRoot; pushEvent(name: string, payload: unknown): void }) {
  const destroyed = LaunchForm.destroyed
  assert.ok(destroyed, "LaunchForm.destroyed must exist")
  destroyed.call(context as never)
}

describe("launch-form hook", () => {
  beforeEach(() => {
    installDomGlobals()
    globalThis.window = {
      location: {
        host: "autolaunch.test",
        origin: "https://autolaunch.test",
      },
    } as Window & typeof globalThis
  })

  afterEach(() => {
    restoreGlobals()
  })

  it("accepts Sepolia and rejects other chain ids", () => {
    assert.equal(parseLaunchChainId("11155111"), 11_155_111)
    assert.equal(parseLaunchChainId("1"), null)
    assert.equal(parseLaunchChainId(undefined), null)
  })

  it("builds a SIWA message tied to the current origin", () => {
    const message = buildSiwaMessage({
      walletAddress: "0x1111111111111111111111111111111111111111",
      chainId: 11_155_111,
      nonce: "nonce-1",
      issuedAt: "2026-03-28T12:00:00.000Z",
    })

    assert.match(message, /autolaunch\.test wants you to sign in/)
    assert.match(message, /Chain ID: 11155111/)
    assert.match(message, /URI: https:\/\/autolaunch\.test\//)
  })

  it("reads launch fields and checkbox values from the form", () => {
    const button = new FakeButton({})
    const form = new FakeRoot(button, [
      new FakeInputElement("launch[token_name]", "Atlas Coin"),
      new FakeInputElement("launch[broadcast]", "", "checkbox", true),
      new FakeTextAreaElement("launch[launch_notes]", "Short launch note"),
      new FakeInputElement("ignored[field]", "skip-me"),
    ])

    assert.deepEqual(readForm(form as unknown as HTMLElement), {
      token_name: "Atlas Coin",
      broadcast: true,
      launch_notes: "Short launch note",
    })
  })

  it("normalizes launch endpoints and request bodies through pure helpers", () => {
    assert.deepEqual(launchEndpoints({}), {
      nonceEndpoint: "/v1/agent/siwa/nonce",
      launchEndpoint: "/api/launch/jobs",
    })

    assert.deepEqual(
      launchEndpoints({
        nonceEndpoint: " /custom/nonce ",
        launchEndpoint: " /custom/jobs ",
      } as DOMStringMap),
      {
        nonceEndpoint: "/custom/nonce",
        launchEndpoint: "/custom/jobs",
      },
    )

    assert.deepEqual(
      buildLaunchRequestBody({
        form: { agent_id: "11155111:42", broadcast: true },
        walletAddress: "0xabc",
        nonce: "nonce-1",
        message: "hello",
        signature: "0xsigned",
        issuedAt: "2026-03-28T12:00:00.000Z",
      }),
      {
        agent_id: "11155111:42",
        broadcast: true,
        wallet_address: "0xabc",
        nonce: "nonce-1",
        message: "hello",
        signature: "0xsigned",
        issued_at: "2026-03-28T12:00:00.000Z",
      },
    )
  })

  it("pushes a browser-wallet error when no wallet is available", async () => {
    const button = new FakeButton({ launchChainId: "11155111" })
    const { context, pushed } = hookContext(button)

    mountLaunchForm(context)
    await button.click()

    assert.deepEqual(pushed, [
      { name: "launch_error", payload: { message: "Connect an EVM wallet in this browser first." } },
    ])
  })

  it("replaces stale click listeners on remount and removes them on destroy", async () => {
    const button = new FakeButton({ launchChainId: "11155111" })
    const { context, pushed } = hookContext(button)

    mountLaunchForm(context)
    mountLaunchForm(context)
    await button.click()

    assert.deepEqual(pushed, [
      { name: "launch_error", payload: { message: "Connect an EVM wallet in this browser first." } },
    ])

    destroyLaunchForm(context)
    await button.click()

    assert.deepEqual(pushed, [
      { name: "launch_error", payload: { message: "Connect an EVM wallet in this browser first." } },
    ])
  })

  it("queues the launch when wallet signing and both requests succeed", async () => {
    const button = new FakeButton({
      launchChainId: "11155111",
      nonceEndpoint: "/v1/agent/siwa/nonce",
      launchEndpoint: "/api/launch/jobs",
    })

    const { context, pushed } = hookContext(button, [
      new FakeInputElement("launch[agent_id]", "11155111:42"),
      new FakeInputElement("launch[token_name]", "Atlas Coin"),
      new FakeInputElement("launch[token_symbol]", "ATLAS"),
    ])

    const fetchCalls: FetchCall[] = []

    globalThis.window = {
      location: {
        host: "autolaunch.test",
        origin: "https://autolaunch.test",
      },
      ethereum: {
        async request(args: { method: string }) {
          if (args.method === "eth_requestAccounts") {
            return ["0x1111111111111111111111111111111111111111"]
          }

          if (args.method === "personal_sign") {
            return "0xsigned"
          }

          throw new Error(`unexpected method: ${args.method}`)
        },
      },
    } as unknown as Window & typeof globalThis

    globalThis.fetch = (async (url: string | URL | Request, init?: RequestInit) => {
      fetchCalls.push({ url, init })

      if (String(url) === "/v1/agent/siwa/nonce") {
        return {
          ok: true,
          async json() {
            return { nonce: "nonce-1" }
          },
        } as Response
      }

      return {
        ok: true,
        async json() {
          return { job_id: "job_123" }
        },
      } as Response
    }) as typeof fetch

    mountLaunchForm(context)
    await button.click()

    assert.equal(fetchCalls.length, 2)
    assert.equal(String(fetchCalls[0].url), "/v1/agent/siwa/nonce")
    assert.equal(String(fetchCalls[1].url), "/api/launch/jobs")

    const queuedPayload = JSON.parse(String(fetchCalls[1].init?.body))
    assert.equal(queuedPayload.wallet_address, "0x1111111111111111111111111111111111111111")
    assert.equal(queuedPayload.nonce, "nonce-1")
    assert.equal(queuedPayload.agent_id, "11155111:42")
    assert.equal(fetchCalls[1].init?.headers && (fetchCalls[1].init.headers as Record<string, string>)["x-csrf-token"], "csrf-123")

    assert.deepEqual(pushed[0], { name: "launch_submitting", payload: {} })
    assert.deepEqual(pushed.at(-1), { name: "launch_queued", payload: { job_id: "job_123" } })
  })

  it("surfaces nonce issuance failures from the sidecar", async () => {
    const button = new FakeButton({ launchChainId: "11155111", nonceEndpoint: "/v1/agent/siwa/nonce" })
    const { context, pushed } = hookContext(button)

    globalThis.window = {
      location: {
        host: "autolaunch.test",
        origin: "https://autolaunch.test",
      },
      ethereum: {
        async request(args: { method: string }) {
          if (args.method === "eth_requestAccounts") {
            return ["0x1111111111111111111111111111111111111111"]
          }

          throw new Error(`unexpected method: ${args.method}`)
        },
      },
    } as unknown as Window & typeof globalThis

    globalThis.fetch = (async () =>
      ({
        ok: false,
        async json() {
          return { error: { message: "SIWA nonce service is unavailable." } }
        },
      }) as Response) as typeof fetch

    mountLaunchForm(context)
    await button.click()

    assert.deepEqual(pushed[0], { name: "launch_submitting", payload: {} })
    assert.deepEqual(pushed.at(-1), {
      name: "launch_error",
      payload: { message: "SIWA nonce service is unavailable." },
    })
  })
})
