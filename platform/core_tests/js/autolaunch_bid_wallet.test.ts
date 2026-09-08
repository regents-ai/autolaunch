import {getAddress, type Address, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {
  releaseHash,
  rememberOperation,
  retainHash,
  retainedHash,
} from "../../assets/js/hooks/autolaunch_bid_wallet"
import {
  sendBidStep,
  sendableStep,
  userRejected,
  type BidClients,
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

})
