import {getAddress, type Hash, type Hex} from "viem"
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {press, type Review} from "../js/hooks/onchain_steps"
import {replaceActiveEthereumWallet, type EthereumProvider} from "../js/wallet_actions/connected_wallet"

const signer = getAddress("0x1111111111111111111111111111111111111111")
const other = getAddress("0x4444444444444444444444444444444444444444")
const target = getAddress("0x2222222222222222222222222222222222222222")
const firstHash = `0x${"ab".repeat(32)}` as Hash
const secondHash = `0x${"cd".repeat(32)}` as Hash

const review: Review = {
  id: "review-1",
  component_id: "card",
  signer,
  chain: {chain_id: 8453, name: "Base", rpc_url: "https://base.example.test"},
  steps: [{kind: "transaction", step: "bid", to: target, data: "0xa52c8728ff" as Hex, value: "0x0" as Hex}],
  inputs: {},
}

type Answers = Partial<Record<string, (params?: unknown[]) => unknown>>

// A wallet on Base holding the reviewed signer, with any answer replaced.
function wallet(answers: Answers = {}) {
  const request = vi.fn(async ({method, params}: {method: string; params?: unknown[]}) => {
    const answer = answers[method]
    if (answer) return answer(params)
    if (method === "eth_chainId") return "0x2105"
    if (method === "eth_accounts") return [signer]
    if (method === "wallet_switchEthereumChain") return null
    if (method === "eth_sendTransaction") return firstHash
    throw new Error(`Unexpected wallet method ${method}`)
  })
  return {request}
}

const methods = (provider: ReturnType<typeof wallet>) => provider.request.mock.calls.map(([call]) => call.method)

const activate = (provider: EthereumProvider, address: string = signer) =>
  replaceActiveEthereumWallet({address, provider})

beforeEach(() => {
  vi.stubGlobal("window", {location: {origin: "https://autolaunch.sh"}, dispatchEvent: vi.fn()})
})

afterEach(() => {
  replaceActiveEthereumWallet(null)
  vi.unstubAllGlobals()
})

describe("a wallet button sends only the step the server built", () => {
  it("hands the wallet the exact reviewed bytes from the reviewed signer and reports the hash once", async () => {
    const provider = wallet()
    activate(provider)
    const push = vi.fn()

    await expect(press(review, "bid", push)).resolves.toEqual({transaction_hash: firstHash})

    expect(provider.request).toHaveBeenCalledWith({
      method: "eth_sendTransaction",
      params: [{from: signer, to: target, data: "0xa52c8728ff", value: "0x0"}],
    })
    // The chain is the last thing read before the send.
    expect(methods(provider).slice(-2)).toEqual(["eth_chainId", "eth_sendTransaction"])
    expect(push.mock.calls).toEqual([["step_sent", {review_id: "review-1", step: "bid", transaction_hash: firstHash}]])
  })

  it("two presses in a row both reach the wallet while the first is still there", async () => {
    let answerFirst: (hash: Hash) => void = () => {}
    let sends = 0
    const provider = wallet({
      eth_sendTransaction: () => {
        sends += 1
        return sends === 1 ? new Promise<Hash>(resolve => (answerFirst = resolve)) : secondHash
      },
    })
    activate(provider)
    const push = vi.fn()

    const first = press(review, "bid", push)
    const second = press(review, "bid", push)
    await expect(second).resolves.toEqual({transaction_hash: secondHash})
    answerFirst(firstHash)
    await expect(first).resolves.toEqual({transaction_hash: firstHash})

    expect(methods(provider).filter(method => method === "eth_sendTransaction")).toHaveLength(2)
    expect(push.mock.calls.map(([, payload]) => payload.transaction_hash)).toEqual([secondHash, firstHash])
  })

  it("sends nothing from a wallet other than the reviewed signer", async () => {
    const elsewhere = wallet({eth_accounts: () => [other]})
    activate(elsewhere, other)
    const push = vi.fn()
    await expect(press(review, "bid", push)).resolves.toEqual({reason: "wallet_unavailable"})
    expect(methods(elsewhere)).not.toContain("eth_sendTransaction")

    // Privy says the signer is active, but the wallet answers for another account.
    const swapped = wallet({eth_accounts: () => [other]})
    activate(swapped)
    await expect(press(review, "bid", push)).resolves.toEqual({reason: "wallet_unavailable"})
    expect(methods(swapped)).not.toContain("eth_sendTransaction")
    expect(push.mock.calls.map(([event]) => event)).toEqual(["step_failed", "step_failed"])
  })

  it("sends nothing while the wallet is on another chain", async () => {
    const refused = wallet({
      eth_chainId: () => "0x1",
      wallet_switchEthereumChain: () => {
        throw Object.assign(new Error("rejected"), {code: 4001})
      },
    })
    activate(refused)
    await expect(press(review, "bid", vi.fn())).resolves.toEqual({reason: "network_mismatch"})
    expect(methods(refused)).not.toContain("eth_sendTransaction")

    // The switch succeeds, but the wallet moves again before the send.
    let reads = 0
    const drifting = wallet({eth_chainId: () => (++reads < 2 ? "0x2105" : "0x1")})
    activate(drifting)
    await expect(press(review, "bid", vi.fn())).resolves.toEqual({reason: "network_mismatch"})
    expect(methods(drifting)).not.toContain("eth_sendTransaction")
  })

  it("sends nothing when Privy changes the active wallet part-way", async () => {
    const replacement = wallet()
    const provider = wallet({
      eth_accounts: () => {
        activate(replacement)
        return [signer]
      },
    })
    activate(provider)

    await expect(press(review, "bid", vi.fn())).resolves.toEqual({reason: "wallet_unavailable"})
    expect(methods(provider)).not.toContain("eth_sendTransaction")
    expect(methods(replacement)).toEqual([])
  })

  it("reports a declined request and a step the review does not have", async () => {
    const provider = wallet({
      eth_sendTransaction: () => {
        throw Object.assign(new Error("User rejected the request."), {code: 4001})
      },
    })
    activate(provider)
    const push = vi.fn()

    await expect(press(review, "bid", push)).resolves.toEqual({reason: "wallet_declined"})
    await expect(press(review, "claim", push)).resolves.toEqual({reason: "step_unknown"})
    expect(methods(provider).filter(method => method === "eth_sendTransaction")).toHaveLength(1)
    expect(push.mock.calls).toEqual([
      ["step_failed", {step: "bid", reason: "wallet_declined"}],
      ["step_failed", {step: "claim", reason: "step_unknown"}],
    ])
  })

  // A step the chain would refuse once said "Your wallet declined this".
  it("reports a step the chain would refuse as one that can't be sent as it stands", async () => {
    const provider = wallet({
      eth_sendTransaction: () => {
        throw new Error("estimate failed", {cause: {code: 3, message: "execution reverted"}})
      },
    })
    activate(provider)

    await expect(press(review, "bid", vi.fn())).resolves.toEqual({reason: "step_unknown"})
  })
})
