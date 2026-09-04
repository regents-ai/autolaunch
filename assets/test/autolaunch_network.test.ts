import {getAddress, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {
  autolaunchLabChainId,
  labNetwork,
  sendLabTransaction,
  type AutolaunchLabBinding,
} from "../js/wallet_actions/autolaunch_network"
import type {EthereumProvider} from "../js/wallet_actions/connected_wallet"

const wallet = getAddress("0x1111111111111111111111111111111111111111")
const other = getAddress("0x2222222222222222222222222222222222222222")
const target = getAddress("0x3333333333333333333333333333333333333333")
const hash = `0x${"ab".repeat(32)}` as Hash
const blockHash = `0x${"12".repeat(32)}` as Hash
const data = "0x1234" as Hex

function binding(overrides: Partial<AutolaunchLabBinding> = {}): AutolaunchLabBinding {
  return {
    run_id: "acceptance-run-1",
    rpc_url: "http://127.0.0.1:8545",
    chain_id: autolaunchLabChainId,
    addresses: {factory: target.toLowerCase()},
    ...overrides,
  }
}

function operation(overrides: Record<string, unknown> = {}) {
  return {
    signer: wallet,
    chain_id: autolaunchLabChainId,
    lab: binding(),
    lab_anchor: {block_number: 123, block_hash: blockHash},
    ...overrides,
  }
}

function selected(provider: EthereumProvider, address: string = wallet) {
  return () => ({address, provider})
}

describe("the signed lab network binding is a closed loopback boundary", () => {
  it("accepts ordinary Base only without a lab binding", () => {
    expect(labNetwork({chain_id: 8453, lab: null, lab_anchor: null})).toBeNull()
    expect(() => labNetwork({chain_id: autolaunchLabChainId, lab: null, lab_anchor: null})).toThrow(
      "not for Base",
    )
  })

  it("accepts only chain 31337 and a canonical literal-loopback RPC", () => {
    expect(labNetwork(operation())).toEqual({
      chainId: autolaunchLabChainId,
      rpcUrl: "http://127.0.0.1:8545",
    })

    for (const rpc_url of [
      "http://localhost:8545",
      "https://127.0.0.1:8545",
      "http://127.0.0.1:8545/",
      "http://127.0.0.1:08545",
      "http://127.0.0.1:65536",
      "http://127.0.0.2:8545",
    ]) {
      expect(() => labNetwork(operation({lab: binding({rpc_url})}))).toThrow(
        "network binding changed",
      )
    }
  })

  it("refuses Base and malformed address bindings whenever lab mode is present", () => {
    expect(() => labNetwork(operation({chain_id: 8453}))).toThrow(
      "cannot use Base",
    )
    expect(() =>
      labNetwork(operation({lab: binding({chain_id: 8453})})),
    ).toThrow("network binding changed")
    expect(() =>
      labNetwork(
        operation({
          lab: binding({addresses: {factory: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}),
        }),
      ),
    ).toThrow("network binding changed")
    expect(() =>
      labNetwork(operation({lab: {...binding(), extra: true} as AutolaunchLabBinding})),
    ).toThrow("network binding changed")
  })

  it("requires the exact non-empty server run binding", () => {
    const {run_id: _runId, ...withoutRunId} = binding()

    expect(() =>
      labNetwork(operation({lab: withoutRunId as AutolaunchLabBinding})),
    ).toThrow("network binding changed")
    expect(() =>
      labNetwork(operation({lab: binding({run_id: "  "})})),
    ).toThrow("network binding changed")
  })
})

describe("each local send rechecks account and chain at the provider boundary", () => {
  it("adds the exact ephemeral chain and makes eth_chainId the final request before send", async () => {
    const order: string[] = []
    let switched = false
    let switchAttempts = 0
    const request = vi.fn(async ({method, params}: {method: string; params?: unknown[]}) => {
      order.push(method)
      if (method === "eth_chainId") return switched ? "0x7a69" : "0x2105"
      if (method === "wallet_switchEthereumChain") {
        switchAttempts += 1
        if (switchAttempts === 1) throw {code: 4902}
        switched = true
        return null
      }
      if (method === "wallet_addEthereumChain") {
        expect(params).toEqual([
          {
            chainId: "0x7a69",
            chainName: "Autolaunch Local Lab",
            nativeCurrency: {name: "Local Ether", symbol: "ETH", decimals: 18},
            rpcUrls: ["http://127.0.0.1:8545"],
          },
        ])
        expect(JSON.stringify(params)).not.toContain("blockExplorer")
        return null
      }
      if (method === "eth_accounts") return [wallet]
      if (method === "eth_getBlockByNumber") {
        expect(params).toEqual(["0x7b", false])
        return {hash: blockHash}
      }
      if (method === "eth_sendTransaction") return hash
      throw new Error(`Unexpected provider method ${method}`)
    })
    const provider: EthereumProvider = {request}

    const result = await sendLabTransaction(
      operation(),
      {to: target, data},
      selected(provider),
      () => order.push("send-started"),
    )

    expect(result).toBe(hash)
    expect(order).toEqual([
      "eth_chainId",
      "wallet_switchEthereumChain",
      "wallet_addEthereumChain",
      "wallet_switchEthereumChain",
      "eth_getBlockByNumber",
      "eth_accounts",
      "eth_chainId",
      "send-started",
      "eth_sendTransaction",
    ])
    expect(request).toHaveBeenLastCalledWith({
      method: "eth_sendTransaction",
      params: [{from: wallet, to: target, data, value: "0x0"}],
    })
  })

  it("refuses a final switch back to Base without exposing the transaction", async () => {
    let chainReads = 0
    const request = vi.fn(async ({method}: {method: string}) => {
      if (method === "eth_chainId") {
        chainReads += 1
        return chainReads === 1 ? "0x7a69" : "0x2105"
      }
      if (method === "eth_accounts") return [wallet]
      if (method === "eth_getBlockByNumber") return {hash: blockHash}
      if (method === "eth_sendTransaction") return hash
      throw new Error(`Unexpected provider method ${method}`)
    })
    const marked = vi.fn()

    await expect(
      sendLabTransaction(operation(), {to: target, data}, selected({request}), marked),
    ).rejects.toThrow("Switch to the local Autolaunch lab")
    expect(marked).not.toHaveBeenCalled()
    expect(request.mock.calls.map(([request]) => request.method)).not.toContain(
      "eth_sendTransaction",
    )
  })

  it("reacquires the account independently for every distinct send", async () => {
    let account: string = wallet
    let sent = 0
    const request = vi.fn(async ({method}: {method: string}) => {
      if (method === "eth_chainId") return "0x7a69"
      if (method === "eth_accounts") return [account]
      if (method === "eth_getBlockByNumber") return {hash: blockHash}
      if (method === "eth_sendTransaction") {
        sent += 1
        return `0x${sent.toString(16).padStart(64, "0")}`
      }
      throw new Error(`Unexpected provider method ${method}`)
    })
    const provider: EthereumProvider = {request}

    await sendLabTransaction(operation(), {to: target, data}, selected(provider), vi.fn())
    account = other
    await expect(
      sendLabTransaction(operation(), {to: target, data}, selected(provider), vi.fn()),
    ).rejects.toThrow("wallet this action was reviewed for")

    expect(request.mock.calls.filter(([request]) => request.method === "eth_accounts")).toHaveLength(
      2,
    )
    expect(request.mock.calls.filter(([request]) => request.method === "eth_sendTransaction")).toHaveLength(
      1,
    )
  })

  it("refreshes an old same-chain lab to the exact current loopback RPC before send", async () => {
    let currentLab = "old"
    const request = vi.fn(async ({method, params}: {method: string; params?: unknown[]}) => {
      if (method === "eth_chainId") return "0x7a69"
      if (method === "eth_accounts") return [wallet]
      if (method === "eth_getBlockByNumber") {
        return {hash: currentLab === "old" ? `0x${"34".repeat(32)}` : blockHash}
      }
      if (method === "wallet_addEthereumChain") {
        expect(params).toEqual([
          {
            chainId: "0x7a69",
            chainName: "Autolaunch Local Lab",
            nativeCurrency: {name: "Local Ether", symbol: "ETH", decimals: 18},
            rpcUrls: ["http://127.0.0.1:8545"],
          },
        ])
        currentLab = "current"
        return null
      }
      if (method === "wallet_switchEthereumChain") return null
      if (method === "eth_sendTransaction") return hash
      throw new Error(`Unexpected provider method ${method}`)
    })
    const marked = vi.fn()

    await expect(
      sendLabTransaction(operation(), {to: target, data}, selected({request}), marked),
    ).resolves.toBe(hash)
    expect(request.mock.calls.map(([request]) => request.method)).toEqual(
      expect.arrayContaining(["wallet_addEthereumChain", "wallet_switchEthereumChain"]),
    )
    expect(marked).toHaveBeenCalledOnce()
  })

  it("refuses a stale same-chain lab when the wallet cannot establish the current RPC", async () => {
    const request = vi.fn(async ({method}: {method: string}) => {
      if (method === "eth_chainId") return "0x7a69"
      if (method === "eth_getBlockByNumber") return {hash: `0x${"34".repeat(32)}`}
      if (method === "wallet_addEthereumChain") throw new Error("already configured")
      if (method === "eth_sendTransaction") return hash
      throw new Error(`Unexpected provider method ${method}`)
    })
    const marked = vi.fn()

    await expect(
      sendLabTransaction(operation(), {to: target, data}, selected({request}), marked),
    ).rejects.toThrow("could not connect to the current local lab")
    expect(marked).not.toHaveBeenCalled()
    expect(request.mock.calls.map(([request]) => request.method)).not.toContain(
      "eth_sendTransaction",
    )
  })

  it("refuses when Privy changes the selected provider during setup", async () => {
    const first = {
      request: vi.fn(async ({method}: {method: string}) => {
        if (method === "eth_chainId") return "0x7a69"
        if (method === "eth_accounts") return [wallet]
        throw new Error(`Unexpected provider method ${method}`)
      }),
    }
    const second = {request: vi.fn(async () => "0x7a69")}
    let reads = 0
    const resolve = () => ({address: wallet, provider: reads++ === 0 ? first : second})

    await expect(
      sendLabTransaction(operation(), {to: target, data}, resolve, vi.fn()),
    ).rejects.toThrow("selected wallet changed")
    expect(first.request).not.toHaveBeenCalledWith(
      expect.objectContaining({method: "eth_sendTransaction"}),
    )
  })
})
