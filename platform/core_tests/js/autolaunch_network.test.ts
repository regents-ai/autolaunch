import {getAddress, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {
  labNetwork,
  sendLabTransaction,
  type AutolaunchLabBinding,
} from "../../assets/js/wallet_actions/autolaunch_network"
import type {EthereumProvider} from "../../assets/js/wallet_actions/connected_wallet"

const wallet = getAddress("0x1111111111111111111111111111111111111111")
const target = getAddress("0x3333333333333333333333333333333333333333")
const hash = `0x${"ab".repeat(32)}` as Hash
const blockHash = `0x${"12".repeat(32)}` as Hash
const data = "0x1234" as Hex

function binding(overrides: Partial<AutolaunchLabBinding> = {}): AutolaunchLabBinding {
  return {
    run_id: "acceptance-run-1",
    rpc_url: "http://127.0.0.1:8545",
    chain_id: 31_337,
    addresses: {factory: target.toLowerCase()},
    ...overrides,
  }
}

function operation(overrides: Record<string, unknown> = {}) {
  return {
    signer: wallet,
    chain_id: 31_337,
    lab: binding(),
    lab_anchor: {block_number: 123, block_hash: blockHash},
    ...overrides,
  }
}

function selected(provider: EthereumProvider, address: string = wallet) {
  return () => ({address, provider})
}

describe("the wallet-facing RPC door admits loopback and https only", () => {
  it("names the chain the binding is for: Base, the local lab or the preview", () => {
    expect(labNetwork(operation())).toEqual({
      chainId: 31_337,
      rpcUrl: "http://127.0.0.1:8545",
      chainName: "Autolaunch Local Lab",
      testChain: true,
    })

    expect(labNetwork(operation({lab: binding({rpc_url: "https://fork.example.test/rpc"})}))).toEqual({
      chainId: 31_337,
      rpcUrl: "https://fork.example.test/rpc",
      chainName: "Autolaunch preview (Base fork)",
      testChain: true,
    })

    expect(
      labNetwork(
        operation({
          chain_id: 8453,
          lab: binding({chain_id: 8453, rpc_url: "https://base.example.test"}),
        }),
      ),
    ).toEqual({
      chainId: 8453,
      rpcUrl: "https://base.example.test",
      chainName: "Base",
      testChain: false,
    })

    expect(
      labNetwork(
        operation({
          chain_id: 4663,
          lab: binding({chain_id: 4663, rpc_url: "https://robinhood.example.test/v2/key"}),
        }),
      ),
    ).toEqual({
      chainId: 4663,
      rpcUrl: "https://robinhood.example.test/v2/key",
      chainName: "Robinhood Chain",
      testChain: false,
    })

    // Base is never reached through a loopback door, and a binding for one
    // chain never sends on another.
    expect(() =>
      labNetwork(operation({chain_id: 8453, lab: binding({chain_id: 8453})})),
    ).toThrow("The network binding changed.")
    expect(() => labNetwork(operation({chain_id: 8453}))).toThrow("The network binding changed.")
  })

  it("refuses plain http off loopback, credentials, queries and fragments", () => {
    for (const rpc_url of [
      "http://fork.example.test:8545",
      "http://autolaunch-fork.internal:8545",
      "http://127.0.0.1:8545/rpc",
      "https://user:secret@fork.example.test",
      "https://fork.example.test/rpc?key=1",
      "https://fork.example.test/rpc#x",
      "ws://fork.example.test",
      "",
    ]) {
      expect(() => labNetwork(operation({lab: binding({rpc_url})}))).toThrow(
        "The network binding changed.",
      )
    }
  })

  it("adds the chain with the https door and the preview name", async () => {
    const chains: unknown[] = []
    const request = vi.fn(async ({method, params}: {method: string; params?: unknown[]}) => {
      if (method === "eth_chainId") return "0x2105"
      if (method === "wallet_switchEthereumChain") {
        if (chains.length === 0) throw Object.assign(new Error("unknown chain"), {code: 4902})
        return null
      }
      if (method === "wallet_addEthereumChain") {
        chains.push(params?.[0])
        return null
      }
      if (method === "eth_getBlockByNumber") return {hash: blockHash}
      if (method === "eth_accounts") return [wallet]
      throw new Error(`Unexpected provider method ${method}`)
    })

    await expect(
      sendLabTransaction(
        operation({lab: binding({rpc_url: "https://fork.example.test/rpc"})}),
        {to: target, data},
        selected({request}),
        vi.fn(),
      ),
    ).rejects.toThrow("Switch to Autolaunch preview (Base fork)")

    expect(chains).toEqual([
      {
        chainId: "0x7a69",
        chainName: "Autolaunch preview (Base fork)",
        nativeCurrency: {name: "Test Ether", symbol: "ETH", decimals: 18},
        rpcUrls: ["https://fork.example.test/rpc"],
      },
    ])
  })
})

describe("each send rechecks account and chain at the provider boundary", () => {

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
    ).rejects.toThrow("Switch to Autolaunch Local Lab")
    expect(marked).not.toHaveBeenCalled()
    expect(request.mock.calls.map(([request]) => request.method)).not.toContain(
      "eth_sendTransaction",
    )
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
    ).rejects.toThrow("could not connect to the current fork")
    expect(marked).not.toHaveBeenCalled()
    expect(request.mock.calls.map(([request]) => request.method)).not.toContain(
      "eth_sendTransaction",
    )
  })

  it("sends on Base without anchoring to the reviewed block", async () => {
    const request = vi.fn(async ({method}: {method: string}) => {
      if (method === "eth_chainId") return "0x2105"
      if (method === "eth_accounts") return [wallet]
      if (method === "eth_sendTransaction") return hash
      throw new Error(`Unexpected provider method ${method}`)
    })

    await expect(
      sendLabTransaction(
        operation({chain_id: 8453, lab: binding({chain_id: 8453, rpc_url: "https://base.example.test"})}),
        {to: target, data},
        selected({request}),
        vi.fn(),
      ),
    ).resolves.toBe(hash)
    expect(request.mock.calls.map(([request]) => request.method)).not.toContain(
      "eth_getBlockByNumber",
    )
  })

})
