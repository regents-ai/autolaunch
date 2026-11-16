import {getAddress, type Hash, type Hex} from "viem"
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {asksServer, OnchainSteps, press, pressCalls, type Review} from "../js/hooks/onchain_steps"
import {replaceActiveEthereumWallet, type EthereumProvider, type SwitchChain} from "../js/wallet_actions/connected_wallet"
import type {Failure} from "../js/wallet_actions/send_step"

type Push = (event: string, payload: unknown) => void

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
    if (method === "eth_sendTransaction") return firstHash
    throw new Error(`Unexpected wallet method ${method}`)
  })
  return {request}
}

const methods = (provider: ReturnType<typeof wallet>) => provider.request.mock.calls.map(([call]) => call.method)

// Privy's switch, for a wallet these cases keep on the review's network: never asked.
const unasked: SwitchChain = async () => {
  throw new Error("The wallet was asked to switch network.")
}

const activate = (provider: EthereumProvider, address: string = signer) =>
  replaceActiveEthereumWallet({address, provider, switchChain: unasked})

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
      params: [{from: signer, to: target, data: "0xa52c8728ff", value: "0x0", chainId: "0x2105"}],
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
    // The wallet is on Base at the first read and moves off it before the send.
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

// BATCH_SENDS_ONLY_THE_REVIEW_ATOMICALLY: a batch press hands the wallet every
// reviewed call, unchanged and in order, from the reviewed signer, with
// atomicity required; a wallet that cannot send them atomically sends nothing.
describe("a batch press sends the review's calls together or not at all", () => {
  const claim = getAddress("0x3333333333333333333333333333333333333333")
  const batch: Review = {
    ...review,
    id: "review-batch",
    steps: [
      {kind: "transaction", step: "collect_full_range", to: target, data: "0xddc1f59d01" as Hex, value: "0x0" as Hex},
      {kind: "transaction", step: "claim", to: claim, data: "0xd1058e59" as Hex, value: "0x0" as Hex},
    ],
  }
  const receipt = {logs: [], status: "0x1", blockHash: firstHash, blockNumber: "0x1", gasUsed: "0x1", transactionHash: firstHash}

  it("hands wallet_sendCalls exactly the reviewed calls, atomically, after the chain read", async () => {
    const provider = wallet({
      wallet_sendCalls: () => ({id: "batch-1"}),
      wallet_getCallsStatus: () => ({version: "2.0.0", id: "batch-1", chainId: "0x2105", status: 200, atomic: true, receipts: [receipt]}),
    })
    activate(provider)
    const push = vi.fn()

    await expect(pressCalls(batch, push)).resolves.toEqual({calls_id: "batch-1"})

    const sent = provider.request.mock.calls.find(([call]) => call.method === "wallet_sendCalls")?.[0]
    expect(sent?.params).toEqual([{
      atomicRequired: true,
      calls: [{to: target, data: "0xddc1f59d01", value: undefined}, {to: claim, data: "0xd1058e59", value: undefined}],
      capabilities: undefined,
      chainId: "0x2105",
      from: signer,
      id: undefined,
      version: "2.0.0",
    }])
    // The chain is the last thing read before the batch.
    const order = methods(provider)
    expect(order[order.indexOf("wallet_sendCalls") - 1]).toEqual("eth_chainId")
    await vi.waitFor(() => expect(push).toHaveBeenCalledWith("calls_landed", {calls_id: "batch-1", transaction_hash: firstHash}))
    expect(push.mock.calls[0]).toEqual(["calls_sent", {review_id: "review-batch", calls_id: "batch-1"}])
  })

  it("sends nothing when the wallet cannot send the calls atomically, and says so", async () => {
    const provider = wallet({
      wallet_sendCalls: () => {
        throw Object.assign(new Error("Atomicity not supported"), {code: 5760})
      },
    })
    activate(provider)
    const push = vi.fn()

    await expect(pressCalls(batch, push)).resolves.toEqual({reason: "step_unknown"})
    expect(methods(provider)).not.toContain("eth_sendTransaction")
    expect(push.mock.calls).toEqual([
      ["onchain_atomic", {review_id: "review-batch", atomic: false}],
      ["step_failed", {step: "calls", reason: "step_unknown"}],
    ])
  })
})

// Invariant: a wallet on another network is moved by Privy's own switch, which
// knows how each wallet app adds a network, before anything is sent, on every
// press and for each of the site's two networks; a wallet already on the step's
// network is never asked. Nothing reaches the wallet's send while it is off the
// step's network, and the press says which: the person said no to the switch
// (4001, however the wallet wraps it), or the wallet could not switch or is
// still elsewhere.
describe("a press off the step's network asks Privy's switch for it", () => {
  const base = 8453
  const robinhood = 4663
  const onRobinhood: Review = {
    ...review,
    id: "review-robinhood",
    chain: {chain_id: robinhood, name: "Robinhood Chain", rpc_url: "https://robinhood.example.test"},
  }
  const together = (sent: Review): Review => ({
    ...sent,
    id: `${sent.id}-together`,
    steps: [...sent.steps, {kind: "transaction", step: "claim", to: other, data: "0xd1058e59" as Hex, value: "0x0" as Hex}],
  })

  // A wallet app holding the signer on network `on`, which moves only through
  // Privy's switch (`switching` says what that switch does with each ask), as
  // Privy's active wallet. It remembers each ask.
  function walletOn(on: number, switching: (wanted: number) => number | Error = wanted => wanted) {
    let current = on
    const switches: number[] = []
    const provider = wallet({
      eth_chainId: () => `0x${current.toString(16)}`,
      wallet_sendCalls: () => ({id: "batch-1"}),
      wallet_getCallsStatus: () => ({version: "2.0.0", id: "batch-1", chainId: `0x${current.toString(16)}`, status: 200, atomic: true, receipts: []}),
    })
    replaceActiveEthereumWallet({
      address: signer,
      provider,
      switchChain: async wanted => {
        switches.push(wanted)
        const answer = switching(wanted)
        if (answer instanceof Error) throw answer
        current = answer
      },
    })
    const sends = () => methods(provider).filter(method => method === "eth_sendTransaction" || method === "wallet_sendCalls")
    return {switches, sends}
  }

  const walletError = (code: number, message: string) => Object.assign(new Error(message), {code})

  it("asks only when the wallet is off the step's network, for a Base or Robinhood step sent alone or together", async () => {
    for (const [sent, elsewhere] of [[review, robinhood], [onRobinhood, base]] as const) {
      for (const send of [() => press(sent, "bid", vi.fn()), () => pressCalls(together(sent), vi.fn())]) {
        const there = walletOn(sent.chain.chain_id)
        await send()
        expect(there.switches).toEqual([])
        expect(there.sends()).toHaveLength(1)

        const away = walletOn(elsewhere)
        await send()
        expect(away.switches).toEqual([sent.chain.chain_id])
        expect(away.sends()).toHaveLength(1)
      }
    }
  })

  it("asks again on every press while the wallet stays elsewhere", async () => {
    const {switches, sends} = walletOn(robinhood, () => walletError(4001, "User rejected the request."))

    for (let pressed = 0; pressed < 3; pressed++) {
      await expect(press(review, "bid", vi.fn())).resolves.toEqual({reason: "switch_declined"})
    }
    expect(switches).toEqual([base, base, base])
    expect(sends()).toEqual([])
  })

  it("sends nothing, and tells a declined switch from a failed one", async () => {
    const cases: Array<[Failure, (wanted: number) => number | Error]> = [
      ["switch_declined", () => walletError(4001, "User rejected the request.")],
      ["switch_declined", () => Object.assign(new Error("wrapped"), {cause: walletError(4001, "rejected")})],
      ["network_mismatch", () => walletError(4902, "Unrecognized chain ID")],
      // Privy refuses a network outside its supportedChains with no code.
      ["network_mismatch", () => new Error("Unsupported chainId: 8453")],
      ["network_mismatch", () => walletError(-32603, "Internal error")],
      // The switch answered, but the wallet still reports another network.
      ["network_mismatch", () => robinhood],
    ]

    for (const [reason, switching] of cases) {
      for (const [step, send] of [
        ["bid", (push: Push) => press(review, "bid", push)],
        ["calls", (push: Push) => pressCalls(together(review), push)],
      ] as const) {
        const held = walletOn(robinhood, switching)
        const push = vi.fn()

        await expect(send(push)).resolves.toEqual({reason})
        expect(push.mock.calls).toEqual([["step_failed", {step, reason}]])
        expect(held.switches).toEqual([base])
        expect(held.sends()).toEqual([])
      }
    }
  })
})

// SETTLE_PRESS_BEFORE_REVIEW_SENDS: a settlement card's button names its action
// before its review arrives, and a press then sent nothing (found by the agent
// journeys, 28 Oct 2026).
describe("a press with no review yet asks the server for one when the card prepares on press", () => {
  it("asks on a card marked to prepare on press, and on a card whose inputs have no matching review", () => {
    expect(asksServer(undefined, {}, true)).toBe(true)
    expect(asksServer(undefined, {amount: "1"}, false)).toBe(true)
    expect(asksServer({...review, inputs: {amount: "1"}}, {amount: "2"}, false)).toBe(true)
  })

  it("sends the review it has, and leaves a card with neither inputs nor that mark as it was", () => {
    expect(asksServer(review, {}, true)).toBe(false)
    expect(asksServer({...review, inputs: {amount: "1"}}, {amount: "1"}, false)).toBe(false)
    expect(asksServer(undefined, {}, false)).toBe(false)
  })
})

// A3 and rule 11: a press while the connection is down still reaches the
// wallet with the review the page holds, and the server that takes over is
// asked for a fresh one (money-path audit and its review, 12 Nov 2026).
describe("a press while the connection is down still reaches the wallet", () => {
  const fresh: Review = {
    ...review,
    id: "review-2",
    steps: [{kind: "transaction", step: "bid", to: target, data: "0xa52c872801" as Hex, value: "0x0" as Hex}],
  }

  // The hook on a card that prepares on press, mounted; `answer` is the
  // server's reply to `prepare_and_send`. While the connection is down,
  // LiveView answers every push as refused, as it does in the browser.
  function mountedCard(answer: Review) {
    let clicked: (event: Event) => void = () => {}
    let reviewed: (payload: unknown) => void = () => {}
    let connected = true
    const el = {
      id: "card",
      hasAttribute: (name: string) => name === "data-onchain-prepare",
      addEventListener: (_event: string, listener: (event: Event) => void) => (clicked = listener),
      querySelectorAll: () => [],
      querySelector: () => null,
    }
    const pushEventTo = vi.fn(async (_target: unknown, event: string) => {
      if (!connected) return [{status: "rejected", reason: new Error("unable to push hook event. LiveView not connected")}]
      return event === "prepare_and_send" ? [{status: "fulfilled", value: {reply: {review: answer, send: "bid"}}}] : []
    })
    const hook = {
      el,
      pushEventTo,
      handleEvent: (_event: string, callback: (payload: unknown) => void) => (reviewed = callback),
    }
    OnchainSteps.mounted!.call(hook)

    const button = {dataset: {onchainStep: "bid"}, hasAttribute: () => false, closest: () => el}
    const target = {closest: (selector: string) => (selector.includes("data-onchain-step") ? button : el)}
    const pressBid = () => clicked({target} as unknown as Event)
    const push = (sent: Review | null) => reviewed({component_id: "card", review: sent})
    const asked = () => pushEventTo.mock.calls.filter(([, event]) => event === "prepare_and_send").length
    const heardWallet = () => pushEventTo.mock.calls.filter(([, event]) => event === "onchain_active_wallet").length
    // LiveView calls these on a hook that has them, as the connection drops and rejoins.
    const dropped = () => {
      connected = false
      OnchainSteps.disconnected?.call(hook)
    }
    const rejoined = () => {
      connected = true
      OnchainSteps.reconnected?.call(hook)
    }

    return {pressBid, push, asked, heardWallet, dropped, rejoined}
  }

  beforeEach(() => {
    vi.stubGlobal("window", {
      location: {origin: "https://autolaunch.sh", hash: ""},
      dispatchEvent: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })
  })

  const sentData = (provider: ReturnType<typeof wallet>) =>
    provider.request.mock.calls
      .filter(([call]) => call.method === "eth_sendTransaction")
      .map(([call]) => (call.params as [{data: string}])[0].data)

  it("sends the review the page holds while the connection is down, and before the server that took over answers", async () => {
    const provider = wallet()
    activate(provider)
    const card = mountedCard(fresh)
    card.push(review)

    card.dropped()
    card.pressBid()
    await vi.waitFor(() => expect(sentData(provider)).toEqual(["0xa52c8728ff"]))

    card.rejoined()
    card.pressBid()
    await vi.waitFor(() => expect(sentData(provider)).toEqual(["0xa52c8728ff", "0xa52c8728ff"]))
    expect(card.asked()).toBe(0)
  })

  it("asks the server that took over for a fresh review as the page rejoins, and sends the one it pushes", async () => {
    const provider = wallet()
    activate(provider)
    const card = mountedCard(review)
    card.push(review)

    card.dropped()
    card.rejoined()
    // The server that took over hears the wallet Privy has active, and answers with its review.
    expect(card.heardWallet()).toBe(2)
    card.push(fresh)
    card.pressBid()

    await vi.waitFor(() => expect(sentData(provider)).toEqual(["0xa52c872801"]))
    expect(card.asked()).toBe(0)
  })
})
