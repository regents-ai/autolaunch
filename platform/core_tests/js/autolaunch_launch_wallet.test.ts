import {getAddress, type Hash, type Hex} from "viem"
import {describe, expect, it, vi} from "vitest"

import {
  addressedTo,
  releaseHash,
  rememberOperation,
  retainHash,
  retainedHash,
} from "../../assets/js/hooks/autolaunch_launch_wallet"
import {
  sendLaunchStep,
  sendableStep,
  userRejected,
  type LaunchClients,
  type LaunchOperation,
} from "../../assets/js/wallet_actions/autolaunch_launch"

const wallet = getAddress("0x1111111111111111111111111111111111111111")
const other = getAddress("0x9999999999999999999999999999999999999999")
const factory = getAddress("0x7777777777777777777777777777777777777777")
const regent = getAddress("0x6f89bcA4eA5931EdFCB09786267b251DeE752b07")
const launchHash = `0x${"cd".repeat(32)}` as Hash
const blockHash = `0x${"12".repeat(32)}` as Hash
const lab = {
  run_id: "acceptance-run-1",
  rpc_url: "http://127.0.0.1:8545",
  chain_id: 31_337,
  addresses: {factory: factory.toLowerCase()},
}

// The reviewed launch calldata is a dynamic tuple the server encoded once. The
// browser only ever forwards it, so this fixture is opaque bytes on purpose.
const launchData = "0x783eed5300000000000000000000000000000000000000000000000000000000000000ff" as Hex

function operation(overrides: Partial<LaunchOperation> = {}): LaunchOperation {
  return {
    action_id: "launch-action",
    signer: wallet,
    chain_id: 8453,
    lab: null,
    lab_anchor: null,
    terminal: false,
    steps: [
      {step: "approval", to: regent, data: "0x095ea7b3ff" as Hex},
      {step: "launch", to: factory, data: launchData},
    ],
    ...overrides,
  }
}

function clients(overrides: Partial<LaunchClients> = {}): LaunchClients {
  return {
    addresses: vi.fn(async () => [wallet]),
    chainId: vi.fn(async () => 8453),
    switchToBase: vi.fn(async () => undefined),
    send: vi.fn(async () => launchHash),
    ...overrides,
  }
}

const provider = {request: vi.fn(async () => null)}
const resolver = (
  selected: {request(args: {method: string; params?: unknown[]}): Promise<unknown>} = provider,
  address: string = wallet,
) => () => ({address, provider: selected})
const clientFactory = (bound: LaunchClients) => () => bound

describe("the browser rechecks the wallet immediately before it sends", () => {

  it("sends the reviewed bytes to the reviewed factory with zero value", async () => {
    const held = operation()
    const order: string[] = []
    const bound = clients({
      addresses: vi.fn(async () => {
        order.push("accounts")
        return [wallet]
      }),
      chainId: vi.fn(async () => {
        order.push("chain")
        return 8453
      }),
      send: vi.fn(async request => {
        order.push("send")
        return launchHash
      }),
    })

    const hash = await sendLaunchStep(
      held,
      held.steps[1],
      resolver(),
      () => order.push("send-started"),
      clientFactory(bound),
    )

    expect(hash).toBe(launchHash)
    expect(order).toEqual(["chain", "accounts", "chain", "send-started", "send"])
    expect(bound.send).toHaveBeenCalledWith({
      account: wallet,
      to: factory,
      data: launchData,
      value: 0n,
    })
  })

  it("refuses when Privy changes the selected provider during a Base switch", async () => {
    const held = operation()
    const firstProvider = {request: vi.fn(async () => null)}
    const secondProvider = {request: vi.fn(async () => null)}
    let selectedProvider = firstProvider
    const resolve = () => ({address: wallet, provider: selectedProvider})
    const boundary = clients({
      chainId: vi.fn(async () => 1),
      switchToBase: vi.fn(async () => {
        selectedProvider = secondProvider
      }),
    })

    await expect(
      sendLaunchStep(held, held.steps[1], resolve, vi.fn(), clientFactory(boundary)),
    ).rejects.toThrow("selected wallet changed")

    expect(boundary.addresses).not.toHaveBeenCalled()
    expect(boundary.send).not.toHaveBeenCalled()
  })

  // The launch tuple is the only dynamic call this product has, and it is
  // encoded once on the server. Nothing in the browser can rebuild it.

})

// A founder with several saved drafts has one card each, and a pushed event
// reaches every hook in the LiveView. Only the card an event names may act on
// it, or one claimed dispatch would open every other card's wallet as well.
