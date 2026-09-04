import {getAddress, type Address, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {
  releaseHash,
  rememberOperation,
  retainHash,
  retainedHash,
} from "../js/hooks/autolaunch_subject_wallet"
import {
  sendSubjectStep,
  sendableStep,
  userRejected,
  type SubjectWalletClients,
  type SubjectWalletOperation,
} from "../js/wallet_actions/autolaunch_subject_wallet"

const wallet = getAddress("0x1111111111111111111111111111111111111111")
const other = getAddress("0x9999999999999999999999999999999999999999")
const splitter = getAddress("0x2222222222222222222222222222222222222222")
const token = getAddress("0x4444444444444444444444444444444444444444")
const approvalHash = `0x${"cd".repeat(32)}` as Hash

function operation(overrides: Partial<SubjectWalletOperation> = {}): SubjectWalletOperation {
  return {
    action_id: "subject-action",
    subject_id: "subject:wallet",
    signer: wallet,
    chain_id: 8453,
    terminal: false,
    steps: [
      {step: "approval", to: token, data: "0x095ea7b3ff" as Hex},
      {step: "action", to: splitter, data: "0xa694fc3aff" as Hex},
    ],
    ...overrides,
  }
}

function clients(overrides: Partial<SubjectWalletClients> = {}): SubjectWalletClients {
  return {
    addresses: vi.fn(async () => [wallet]),
    chainId: vi.fn(async () => 8453),
    switchToBase: vi.fn(async () => undefined),
    send: vi.fn(async () => approvalHash),
    ...overrides,
  }
}

const provider = {request: vi.fn(async () => null)}

describe("the browser sends only the step the server claimed", () => {
  it("returns the reviewed step for this exact operation", () => {
    const held = operation()

    expect(sendableStep(held, "subject-action", "approval")).toEqual(held.steps[0])
    expect(sendableStep(held, "subject-action", "action")).toEqual(held.steps[1])
  })

  it("refuses a different action, a finished one, and another chain", () => {
    expect(() => sendableStep(operation(), "elsewhere", "action")).toThrow(
      "This is a different action.",
    )
    expect(() => sendableStep(operation({terminal: true}), "subject-action", "action")).toThrow(
      "This action has already finished.",
    )
    expect(() => sendableStep(operation({chain_id: 1}), "subject-action", "action")).toThrow(
      "This action is not for Base.",
    )
  })

  it("refuses a step the reviewed sequence does not contain", () => {
    expect(() => sendableStep(operation(), "subject-action", "permit2_approval")).toThrow(
      "This step is not part of the reviewed action.",
    )
  })

  it("refuses bytes that are not the reviewed lowercase calldata", () => {
    const tampered = operation({
      steps: [{step: "action", to: splitter, data: "0xA694FC3AFF" as Hex}],
    })

    expect(() => sendableStep(tampered, "subject-action", "action")).toThrow(
      "The reviewed transaction changed.",
    )
  })
})

describe("the browser rechecks the wallet immediately before it sends", () => {
  it("sends the reviewed bytes to Base with zero value", async () => {
    const held = operation()
    const bound = clients()

    const hash = await sendSubjectStep(held, held.steps[1], provider, () => undefined, bound)

    expect(hash).toBe(approvalHash)
    expect(bound.send).toHaveBeenCalledWith({
      account: wallet,
      to: splitter,
      data: held.steps[1].data,
      value: 0n,
    })
  })

  it("switches to Base once and refuses if the wallet stays elsewhere", async () => {
    const held = operation()
    const stuck = clients({chainId: vi.fn(async () => 1)})

    await expect(
      sendSubjectStep(held, held.steps[1], provider, () => undefined, stuck),
    ).rejects.toThrow("Switch to Base before continuing.")

    expect(stuck.switchToBase).toHaveBeenCalledTimes(1)
    expect(stuck.send).not.toHaveBeenCalled()
  })

  it("refuses when the wallet's own account is no longer the reviewed signer", async () => {
    const held = operation()
    const moved = clients({addresses: vi.fn(async () => [other])})

    await expect(
      sendSubjectStep(held, held.steps[1], provider, () => undefined, moved),
    ).rejects.toThrow("Use the wallet this action was reviewed for.")

    expect(moved.send).not.toHaveBeenCalled()
  })

  it("marks the send as started only immediately before the wallet is asked", async () => {
    const held = operation()
    const order: string[] = []

    const watched = clients({
      send: vi.fn(async () => {
        order.push("send")
        return approvalHash
      }),
    })

    await sendSubjectStep(held, held.steps[1], provider, () => order.push("marked"), watched)

    expect(order).toEqual(["marked", "send"])
  })

  it("never marks a send that failed its own preflight", async () => {
    const held = operation()
    const moved = clients({addresses: vi.fn(async () => [other])})
    const marked = vi.fn()

    await expect(
      sendSubjectStep(held, held.steps[1], provider, marked, moved),
    ).rejects.toThrow()

    expect(marked).not.toHaveBeenCalled()
  })

  it("contains no encoder: the bytes it sends are exactly the bytes it was given", async () => {
    const held = operation()
    const bound = clients()

    await sendSubjectStep(held, held.steps[0], provider, () => undefined, bound)

    const [request] = (bound.send as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(request.data).toBe(held.steps[0].data)
  })
})

describe("only an exact EIP-1193 rejection is a rejection", () => {
  it("finds the code through whatever wrapper it arrived in", () => {
    expect(userRejected({code: 4001})).toBe(true)
    expect(userRejected({cause: {cause: {code: 4001}}})).toBe(true)
  })

  it("never treats message text or another code as a rejection", () => {
    expect(userRejected({message: "User rejected the request."})).toBe(false)
    expect(userRejected({code: -32000})).toBe(false)
    expect(userRejected(null)).toBe(false)

    const circular: {cause?: unknown} = {}
    circular.cause = circular
    expect(userRejected(circular)).toBe(false)
  })
})

describe("browser storage holds a hint and a hash, never authority", () => {
  function storage() {
    const items = new Map<string, string>()

    return {
      items,
      getItem: (key: string) => items.get(key) ?? null,
      setItem: (key: string, value: string) => void items.set(key, value),
      removeItem: (key: string) => void items.delete(key),
    }
  }

  it("remembers only an operation id, and forgets a terminal one", () => {
    const store = storage()

    rememberOperation(operation(), store)
    expect([...store.items.values()]).toEqual(["subject-action"])

    rememberOperation(operation({terminal: true}), store)
    expect(store.items.size).toBe(0)
  })

  it("stores no signer, calldata, chain or outcome", () => {
    const store = storage()
    rememberOperation(operation(), store)

    const stored = [...store.items.values()].join(" ")
    expect(stored).not.toContain(wallet)
    expect(stored).not.toContain("0x095ea7b3ff")
    expect(stored).not.toContain("8453")
  })

  it("replays a reported hash until the server acknowledges that exact one", () => {
    const store = storage()
    const reported = {action_id: "subject-action", step: "action", transaction_hash: approvalHash}

    retainHash(reported, store)
    expect(retainedHash(store)).toEqual(reported)

    // A different action, step or hash leaves the report exactly where it is.
    releaseHash({...reported, action_id: "elsewhere"}, store)
    releaseHash({...reported, step: "approval"}, store)
    releaseHash({...reported, transaction_hash: `0x${"11".repeat(32)}`}, store)
    expect(retainedHash(store)).toEqual(reported)

    // The same hash in another case is still the same transaction.
    releaseHash({...reported, transaction_hash: approvalHash.toUpperCase()}, store)
    expect(retainedHash(store)).toBeNull()
  })

  it("treats a partial or unreadable report as nothing at all", () => {
    const store = storage()

    store.setItem("regent:autolaunch-subject-wallet:hash", "{not json")
    expect(retainedHash(store)).toBeNull()

    store.setItem("regent:autolaunch-subject-wallet:hash", JSON.stringify({action_id: "a"}))
    expect(retainedHash(store)).toBeNull()
  })

  it("survives a browser that refuses storage entirely", () => {
    const refusing = {
      getItem: () => {
        throw new Error("denied")
      },
      setItem: () => {
        throw new Error("denied")
      },
      removeItem: () => {
        throw new Error("denied")
      },
    }

    expect(() => rememberOperation(operation(), refusing)).not.toThrow()
    expect(() => retainHash({action_id: "a", step: "action", transaction_hash: "0x1"}, refusing)).not.toThrow()
    expect(retainedHash(refusing)).toBeNull()
    expect(() => releaseHash({action_id: "a", step: "action", transaction_hash: "0x1"}, refusing)).not.toThrow()
  })
})
