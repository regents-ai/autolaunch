import {getAddress, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {sendLaunchStep, type LaunchOperation} from "../../assets/js/wallet_actions/autolaunch_launch"

const wallet = getAddress("0x1111111111111111111111111111111111111111")
const factory = getAddress("0x7777777777777777777777777777777777777777")
const regent = getAddress("0x6f89bcA4eA5931EdFCB09786267b251DeE752b07")
const launchHash = `0x${"cd".repeat(32)}` as Hash
const blockHash = `0x${"12".repeat(32)}` as Hash
const lab = {
  run_id: "base-2026-09",
  rpc_url: "https://base.example.test",
  chain_id: 8453,
  addresses: {factory: factory.toLowerCase(), regent: regent.toLowerCase()},
}

// The reviewed launch calldata is a dynamic tuple the server encoded once. The
// browser only ever forwards it, so this fixture is opaque bytes on purpose.
const launchData = "0x783eed5300000000000000000000000000000000000000000000000000000000000000ff" as Hex

function operation(overrides: Partial<LaunchOperation> = {}): LaunchOperation {
  return {
    action_id: "launch-action",
    signer: wallet,
    chain_id: 8453,
    lab,
    lab_anchor: {block_number: 30_000_000, block_hash: blockHash},
    terminal: false,
    steps: [
      {step: "approval", to: regent, data: "0x095ea7b3ff" as Hex},
      {step: "launch", to: factory, data: launchData},
    ],
    ...overrides,
  }
}

type Answers = Partial<Record<string, (params?: unknown[]) => unknown>>

// A wallet on Base holding the reviewed signer, with any answer replaced.
function provider(answers: Answers = {}) {
  const request = vi.fn(async ({method, params}: {method: string; params?: unknown[]}) => {
    const answer = answers[method]
    if (answer) return answer(params)
    if (method === "eth_chainId") return "0x2105"
    if (method === "eth_accounts") return [wallet]
    if (method === "wallet_switchEthereumChain") return null
    if (method === "eth_sendTransaction") return launchHash
    throw new Error(`Unexpected provider method ${method}`)
  })
  return {request}
}

const methods = (selected: {request: {mock: {calls: [{method: string}][]}}}) =>
  selected.request.mock.calls.map(([request]) => request.method)

describe("the browser rechecks the wallet immediately before it sends", () => {

  it("sends the reviewed bytes to the reviewed factory with zero value", async () => {
    const held = operation()
    const order: string[] = []
    const bound = provider({
      eth_accounts: () => {
        order.push("accounts")
        return [wallet]
      },
      eth_chainId: () => {
        order.push("chain")
        return "0x2105"
      },
      eth_sendTransaction: () => {
        order.push("send")
        return launchHash
      },
    })

    const hash = await sendLaunchStep(
      held,
      held.steps[1],
      () => ({address: wallet, provider: bound}),
      () => order.push("send-started"),
    )

    expect(hash).toBe(launchHash)
    expect(order).toEqual(["chain", "accounts", "chain", "send-started", "send"])
    expect(bound.request).toHaveBeenCalledWith({
      method: "eth_sendTransaction",
      params: [{from: wallet, to: factory, data: launchData, value: "0x0"}],
    })
  })

  it("refuses when Privy changes the selected provider during a Base switch", async () => {
    const held = operation()
    const secondProvider = provider()
    let selectedProvider: ReturnType<typeof provider> = provider({
      eth_chainId: () => "0x1",
      wallet_switchEthereumChain: () => {
        selectedProvider = secondProvider
        return null
      },
    })
    const firstProvider = selectedProvider
    const resolve = () => ({address: wallet, provider: selectedProvider})

    await expect(sendLaunchStep(held, held.steps[1], resolve, vi.fn())).rejects.toThrow(
      "selected wallet changed",
    )

    expect(methods(firstProvider)).not.toContain("eth_accounts")
    expect(methods(firstProvider)).not.toContain("eth_sendTransaction")
    expect(secondProvider.request).not.toHaveBeenCalled()
  })

  // The launch tuple is the only dynamic call this product has, and it is
  // encoded once on the server. Nothing in the browser can rebuild it.

})
