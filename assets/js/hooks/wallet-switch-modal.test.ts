import assert from "node:assert/strict"
import { afterEach, beforeEach, describe, it } from "node:test"

import { WalletSwitchModal } from "./wallet-switch-modal.ts"

class FakeButton {
  private clickHandlers = new Set<(event: Event) => void>()

  addEventListener(eventName: string, handler: (event: Event) => void) {
    if (eventName === "click") this.clickHandlers.add(handler)
  }

  removeEventListener(eventName: string, handler: (event: Event) => void) {
    if (eventName === "click") this.clickHandlers.delete(handler)
  }

  click() {
    const event = { target: this } as unknown as Event
    this.clickHandlers.forEach((handler) => handler(event))
  }
}

class FakeStatus {
  textContent = ""

  replaceChildren(value: string) {
    this.textContent = value
  }
}

class FakeWalletSwitchRoot {
  dataset: Record<string, string> = {}
  continueButton = new FakeButton()
  status = new FakeStatus()

  querySelector<T extends FakeButton | FakeStatus>(selector: string): T | null {
    if (selector === "[data-wallet-switch-continue]") return this.continueButton as T
    if (selector === "[data-wallet-switch-status]") return this.status as T
    return null
  }
}

const originalWindow = globalThis.window
const originalCustomEvent = globalThis.CustomEvent

function mountWalletSwitchModal(root: FakeWalletSwitchRoot) {
  const mounted = WalletSwitchModal.mounted
  assert.ok(mounted, "WalletSwitchModal.mounted must exist")
  mounted.call({ el: root } as never)
}

describe("wallet-switch-modal hook", () => {
  let dispatched: Array<{ name: string; detail: Record<string, unknown> | undefined }> = []

  beforeEach(() => {
    dispatched = []

    globalThis.CustomEvent = class<T = unknown> {
      type: string
      detail: T

      constructor(type: string, init?: CustomEventInit<T>) {
        this.type = type
        this.detail = init?.detail as T
      }
    } as unknown as typeof CustomEvent

    globalThis.window = {
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent(event: Event) {
        const customEvent = event as CustomEvent<Record<string, unknown>>
        dispatched.push({ name: customEvent.type, detail: customEvent.detail })
        return true
      },
    } as unknown as Window & typeof globalThis
  })

  afterEach(() => {
    globalThis.window = originalWindow
    globalThis.CustomEvent = originalCustomEvent
  })

  it("dispatches the requested wallet when continued", () => {
    const root = new FakeWalletSwitchRoot()
    root.dataset.walletSwitchAddress = "0x2222222222222222222222222222222222222222"

    mountWalletSwitchModal(root)
    root.continueButton.click()

    assert.equal(root.status.textContent, "Open your wallet and confirm the switch to continue.")
    assert.deepEqual(dispatched, [
      {
        name: "autolaunch:switch-wallet",
        detail: { walletAddress: "0x2222222222222222222222222222222222222222" },
      },
    ])
  })
})
