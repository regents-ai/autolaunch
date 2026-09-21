import {getAddress, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {
  sendBidStep,
  sendableStep,
  type BidOperation,
} from "../../assets/js/wallet_actions/autolaunch_bids"

const wallet = getAddress("0x1111111111111111111111111111111111111111")
const other = getAddress("0x4444444444444444444444444444444444444444")
const auction = getAddress("0x2222222222222222222222222222222222222222")
const regent = getAddress("0x6f89bcA4eA5931EdFCB09786267b251DeE752b07")
const permit2 = getAddress("0x000000000022D473030F116dDEE9F6B43aC78BA3")
const approvalHash = `0x${"cd".repeat(32)}` as Hash
const blockHash = `0x${"12".repeat(32)}` as Hash
const lab = {
  run_id: "base-2026-09",
  rpc_url: "https://base.example.test",
  chain_id: 8453,
  addresses: {regent: regent.toLowerCase(), permit2: permit2.toLowerCase()},
}

function operation(overrides: Partial<BidOperation> = {}): BidOperation {
  return {
    action_id: "bid",
    signer: wallet,
    chain_id: 8453,
    lab,
    lab_anchor: {block_number: 30_000_000, block_hash: blockHash},
    terminal: false,
    steps: [
      {step: "token_approval", to: regent, data: "0x095ea7b3ff" as Hex},
      {step: "permit2_approval", to: permit2, data: "0x87517c45ff" as Hex},
      {step: "bid", to: auction, data: "0xa52c8728ff" as Hex},
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
    if (method === "eth_sendTransaction") return approvalHash
    throw new Error(`Unexpected provider method ${method}`)
  })
  return {request}
}

const resolver = (selected: {request: (args: {method: string; params?: unknown[]}) => Promise<unknown>}) =>
  () => ({address: wallet, provider: selected})

const methods = (selected: {request: {mock: {calls: [{method: string}][]}}}) =>
  selected.request.mock.calls.map(([request]) => request.method)

describe("the browser sends only the step the server claimed", () => {

  it("hands the wallet the exact reviewed bytes and reports the hash once", async () => {
    const held = operation()
    const order: string[] = []
    const boundary = provider({
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
        return approvalHash
      },
    })
    const onSendStarted = vi.fn(() => order.push("send-started"))

    const hash = await sendBidStep(
      held,
      sendableStep(held, "bid", "token_approval"),
      resolver(boundary),
      onSendStarted,
    )

    expect(hash).toBe(approvalHash)
    expect(order).toEqual(["chain", "accounts", "chain", "send-started", "send"])
    expect(boundary.request).toHaveBeenCalledWith({
      method: "eth_sendTransaction",
      params: [{from: wallet, to: regent, data: "0x095ea7b3ff", value: "0x0"}],
    })
    expect(onSendStarted).toHaveBeenCalledOnce()
  })

  it("never sends from a wallet other than the reviewed signer", async () => {
    const held = operation()
    const onSendStarted = vi.fn()
    const boundary = provider({eth_accounts: () => [other]})

    await expect(
      sendBidStep(held, sendableStep(held, "bid", "bid"), resolver(boundary), onSendStarted),
    ).rejects.toThrow("wallet this action was reviewed for")

    expect(onSendStarted).not.toHaveBeenCalled()
    expect(methods(boundary)).not.toContain("eth_sendTransaction")
  })

  it("never sends while the wallet is on another chain", async () => {
    const held = operation()
    const boundary = provider({eth_chainId: () => "0x1"})

    await expect(
      sendBidStep(held, sendableStep(held, "bid", "bid"), resolver(boundary), vi.fn()),
    ).rejects.toThrow("Switch to Base")

    expect(methods(boundary)).toContain("wallet_switchEthereumChain")
    expect(methods(boundary)).not.toContain("eth_sendTransaction")
  })

})
