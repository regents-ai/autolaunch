import {getAddress, type Address, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {
  releaseHash,
  rememberOperation,
  retainHash,
  retainedHash,
} from "../js/hooks/autolaunch_bid_wallet"
import {
  sendBidStep,
  sendableStep,
  userRejected,
  type BidClients,
  type BidOperation,
} from "../js/wallet_actions/autolaunch_bids"

const wallet = getAddress("0x1111111111111111111111111111111111111111")
const other = getAddress("0x4444444444444444444444444444444444444444")
const auction = getAddress("0x2222222222222222222222222222222222222222")
const regent = getAddress("0x6f89bcA4eA5931EdFCB09786267b251DeE752b07")
const permit2 = getAddress("0x000000000022D473030F116dDEE9F6B43aC78BA3")
const approvalHash = `0x${"cd".repeat(32)}` as Hash
const blockHash = `0x${"12".repeat(32)}` as Hash
const lab = {
  run_id: "acceptance-run-1",
  rpc_url: "http://127.0.0.1:8545",
  chain_id: 31_337,
  addresses: {auction: auction.toLowerCase(), permit2: permit2.toLowerCase()},
}

function operation(overrides: Partial<BidOperation> = {}): BidOperation {
  return {
    action_id: "bid",
    signer: wallet,
    chain_id: 8453,
    lab: null,
    lab_anchor: null,
    terminal: false,
    steps: [
      {step: "token_approval", to: regent, data: "0x095ea7b3ff" as Hex},
      {step: "permit2_approval", to: permit2, data: "0x87517c45ff" as Hex},
      {step: "bid", to: auction, data: "0xa52c8728ff" as Hex},
    ],
    ...overrides,
  }
}

const resolver = (provider: {request: (args: {method: string; params?: unknown[]}) => Promise<unknown>}, address: string = wallet) =>
  () => ({address, provider})
const factory = (bound: BidClients) => () => bound

function clients(overrides: Partial<BidClients> = {}): BidClients {
  return {
    addresses: vi.fn(async () => [wallet]),
    chainId: vi.fn(async () => 8453),
    switchToBase: vi.fn(async () => undefined),
    send: vi.fn(async () => approvalHash),
    ...overrides,
  }
}

describe("the browser sends only the step the server claimed", () => {
  it("uses the bound local lab instead of the Base client", async () => {
    const held = operation({
      chain_id: 31_337,
      lab,
      lab_anchor: {block_number: 123, block_hash: blockHash},
    })
    const methods: string[] = []
    const provider = {
      request: vi.fn(async ({method}: {method: string}) => {
        methods.push(method)
        if (method === "eth_chainId") return "0x7a69"
        if (method === "eth_accounts") return [wallet]
        if (method === "eth_getBlockByNumber") return {hash: blockHash}
        if (method === "eth_sendTransaction") return approvalHash
        throw new Error(`Unexpected provider method ${method}`)
      }),
    }
    const baseClients = clients()

    await expect(
      sendBidStep(held, held.steps[2], resolver(provider), vi.fn(), factory(baseClients)),
    ).resolves.toBe(approvalHash)
    expect(methods.slice(-2)).toEqual(["eth_chainId", "eth_sendTransaction"])
    expect(baseClients.send).not.toHaveBeenCalled()
  })

  it("hands the wallet the exact reviewed bytes and reports the hash once", async () => {
    const held = operation()
    const order: string[] = []
    const boundary = clients({
      addresses: vi.fn(async () => {
        order.push("accounts")
        return [wallet]
      }),
      chainId: vi.fn(async () => {
        order.push("chain")
        return 8453
      }),
      send: vi.fn(async () => {
        order.push("send")
        return approvalHash
      }),
    })
    const onSendStarted = vi.fn(() => order.push("send-started"))

    const hash = await sendBidStep(
      held,
      sendableStep(held, "bid", "token_approval"),
      resolver({request: vi.fn()}),
      onSendStarted,
      factory(boundary),
    )

    expect(hash).toBe(approvalHash)
    expect(order).toEqual(["chain", "accounts", "chain", "send-started", "send"])
    expect(boundary.send).toHaveBeenCalledWith({
      account: wallet,
      to: regent,
      data: "0x095ea7b3ff",
      value: 0n,
    })
    expect(onSendStarted).toHaveBeenCalledOnce()
  })

  it("refuses another operation, a terminal one, an unknown step and a foreign chain", () => {
    expect(() => sendableStep(operation(), "other", "bid")).toThrow("different bid")
    expect(() => sendableStep(operation({terminal: true}), "bid", "bid")).toThrow("already finished")
    expect(() => sendableStep(operation(), "bid", "exit_bid")).toThrow("not part of the reviewed bid")
    expect(() => sendableStep(operation({chain_id: 1}), "bid", "bid")).toThrow("not for Base")
  })

  it("never sends from a wallet other than the reviewed signer", async () => {
    const held = operation()
    const onSendStarted = vi.fn()

    await expect(
      sendBidStep(
        held,
        sendableStep(held, "bid", "bid"),
        resolver({request: vi.fn()}),
        onSendStarted,
        factory(clients({addresses: vi.fn(async () => [other])})),
      ),
    ).rejects.toThrow("wallet this bid was reviewed for")

    expect(onSendStarted).not.toHaveBeenCalled()
  })

  it("refuses when Privy changes the selected provider during account lookup", async () => {
    const held = operation()
    const firstProvider = {request: vi.fn(async () => null)}
    const secondProvider = {request: vi.fn(async () => null)}
    let selectedProvider = firstProvider
    const resolve = () => ({address: wallet, provider: selectedProvider})
    const boundary = clients({
      addresses: vi.fn(async () => {
        selectedProvider = secondProvider
        return [wallet]
      }),
    })

    await expect(
      sendBidStep(
        held,
        sendableStep(held, "bid", "bid"),
        resolve,
        vi.fn(),
        factory(boundary),
      ),
    ).rejects.toThrow("selected wallet changed")

    expect(boundary.send).not.toHaveBeenCalled()
  })

  it("never sends while the wallet is on another chain", async () => {
    const held = operation()
    const boundary = clients({chainId: vi.fn(async () => 1), switchToBase: vi.fn(async () => undefined)})

    await expect(
      sendBidStep(
        held,
        sendableStep(held, "bid", "bid"),
        resolver({request: vi.fn()}),
        vi.fn(),
        factory(boundary),
      ),
    ).rejects.toThrow("Switch to Base")

    expect(boundary.send).not.toHaveBeenCalled()
  })

  it("stores only the operation identity, and forgets it once the bid ends", () => {
    const storage = {setItem: vi.fn(), removeItem: vi.fn()}

    rememberOperation(operation(), storage)
    expect(storage.setItem).toHaveBeenCalledWith("regent:autolaunch-bid:open", "bid")

    rememberOperation(operation({terminal: true}), storage)
    expect(storage.removeItem).toHaveBeenCalledWith("regent:autolaunch-bid:open")
    expect(storage.setItem).toHaveBeenCalledOnce()
  })

  it("treats only the exact EIP-1193 rejection code as a rejection", () => {
    expect(userRejected({code: 4001})).toBe(true)
    expect(userRejected({cause: {cause: {code: 4001}}})).toBe(true)
    expect(userRejected(new Error("User rejected the request."))).toBe(false)
    expect(userRejected({code: 4100})).toBe(false)
  })
})

describe("a reported hash survives the callback that carried it", () => {
  const reported = {action_id: "bid", step: "token_approval", transaction_hash: approvalHash}

  function storage(initial: Record<string, string> = {}) {
    const items = new Map(Object.entries(initial))

    return {
      items,
      getItem: (key: string) => items.get(key) ?? null,
      setItem: (key: string, value: string) => void items.set(key, value),
      removeItem: (key: string) => void items.delete(key),
    }
  }

  it("retains the hash before the callback and replays exactly what it retained", () => {
    const held = storage()

    retainHash(reported, held)
    expect(retainedHash(held)).toEqual(reported)
  })

  it("keeps replaying until the server acknowledges that exact hash", () => {
    const held = storage()
    retainHash(reported, held)

    releaseHash({...reported, transaction_hash: `0x${"ef".repeat(32)}`}, held)
    releaseHash({...reported, step: "bid"}, held)
    releaseHash({...reported, action_id: "another"}, held)
    releaseHash({durable: true}, held)
    expect(retainedHash(held)).toEqual(reported)

    // Only the server's word, and the server lowercases what it stores.
    releaseHash({...reported, transaction_hash: approvalHash.toUpperCase()}, held)
    expect(retainedHash(held)).toBeNull()
  })

  it("reads nothing back from a partial or unparseable record", () => {
    expect(retainedHash(storage({"regent:autolaunch-bid:hash": "{"}))).toBeNull()
    expect(retainedHash(storage({"regent:autolaunch-bid:hash": '{"action_id":"bid"}'}))).toBeNull()
    expect(retainedHash(storage())).toBeNull()
  })

  it("never throws when the browser refuses storage", () => {
    const denied = {
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

    expect(() => retainHash(reported, denied)).not.toThrow()
    expect(retainedHash(denied)).toBeNull()
    expect(() => releaseHash(reported, denied)).not.toThrow()
    expect(() => rememberOperation(operation(), denied)).not.toThrow()
  })
})
