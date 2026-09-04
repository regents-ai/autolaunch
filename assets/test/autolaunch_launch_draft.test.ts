import {afterEach, describe, expect, it, vi} from "vitest"

import {
  AutolaunchLaunchDraft,
  defaultedTreasury,
  ownershipAfterPatch,
} from "../js/hooks/autolaunch_launch_draft"

const wallet = "0x1111111111111111111111111111111111111111"
const switched = "0x2222222222222222222222222222222222222222"
const typed = "0x9999999999999999999999999999999999999999"

const untouched = (filled: string | null = null) => ({saved: "1", filled, touched: false})
const owned = (filled: string | null = null) => ({saved: "1", filled, touched: true})

describe("the connected wallet is a blank draft's ordinary Treasury default", () => {
  it("fills an empty field with the wallet Privy has selected", () => {
    expect(defaultedTreasury("", wallet, untouched())).toBe(wallet)
  })

  it("leaves the field blank when no Ethereum wallet is selected", () => {
    expect(defaultedTreasury("", null, untouched())).toBeNull()
  })

  it("never overwrites an address the customer entered", () => {
    expect(defaultedTreasury(typed, wallet, owned())).toBeNull()
    expect(defaultedTreasury(typed, switched, owned(wallet))).toBeNull()
  })

  it("refills the blank form a successful save leaves behind", () => {
    expect(defaultedTreasury("", wallet, untouched(wallet))).toBe(wallet)
  })

  it("follows a later wallet change only while the default is untouched", () => {
    expect(defaultedTreasury(wallet, switched, untouched(wallet))).toBe(switched)
  })

  it("writes nothing when the field already holds the selected wallet", () => {
    expect(defaultedTreasury(wallet, wallet, untouched(wallet))).toBeNull()
    expect(defaultedTreasury(wallet, wallet, untouched())).toBeNull()
  })

  // The address the server echoes back after refusing a save reads exactly like
  // the one the default filled in. Only ownership tells them apart.
  it("keeps an address the customer owns even when it matches the default", () => {
    expect(defaultedTreasury(wallet, switched, owned(wallet))).toBeNull()
    expect(defaultedTreasury("", wallet, owned(wallet))).toBeNull()
  })
})

describe("the server's own re-render says who the Treasury belongs to", () => {
  it("hands a refused form to the customer, whatever it holds", () => {
    expect(ownershipAfterPatch(untouched(wallet), "1", true)).toEqual(owned(wallet))
  })

  it("leaves ownership alone when the form comes back without errors", () => {
    expect(ownershipAfterPatch(untouched(wallet), "1", false)).toEqual(untouched(wallet))
    expect(ownershipAfterPatch(owned(typed), "1", false)).toEqual(owned(typed))
  })

  it("starts over once when a draft is saved and the form is cleared", () => {
    const cleared = ownershipAfterPatch(owned(typed), "2", false)
    expect(cleared).toEqual({saved: "2", filled: null, touched: false})

    // Every re-render after that one is an ordinary patch again.
    expect(ownershipAfterPatch(cleared, "2", true)).toEqual({
      saved: "2",
      filled: null,
      touched: true,
    })
  })
})

type Listener = (event: unknown) => void

function listenerRegistry() {
  const listeners = new Map<string, Set<Listener>>()

  return {
    count: (type: string) => listeners.get(type)?.size ?? 0,
    addEventListener(type: string, listener: Listener) {
      listeners.set(type, (listeners.get(type) ?? new Set()).add(listener))
    },
    removeEventListener(type: string, listener: Listener) {
      listeners.get(type)?.delete(listener)
    },
  }
}

afterEach(() => vi.unstubAllGlobals())

describe("the form the draft hook listens to", () => {
  it("is left with nothing listening to it once the page moves on", () => {
    const page = listenerRegistry()
    vi.stubGlobal("window", {...page, location: {origin: "https://example.test"}})

    const form = listenerRegistry()
    const hook = {
      el: {
        ...form,
        dataset: {savedDrafts: "1"},
        querySelector: () => ({value: ""}),
      },
    }

    AutolaunchLaunchDraft.mounted?.call(hook)
    expect(form.count("input")).toBe(1)
    expect(page.count("autolaunch:wallet-state")).toBe(1)

    AutolaunchLaunchDraft.destroyed?.call(hook)
    expect(form.count("input")).toBe(0)
    expect(page.count("autolaunch:wallet-state")).toBe(0)
  })
})
