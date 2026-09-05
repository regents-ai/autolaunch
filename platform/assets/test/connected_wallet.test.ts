import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {
  activeEthereumWallet,
  connectedEthereumWallet,
  eligibleActiveWallet,
  replaceActiveEthereumWallet,
  replaceConnectedEthereumWallets,
  type EthereumProvider,
} from "../js/wallet_actions/connected_wallet"

const first = "0x1111111111111111111111111111111111111111"
const second = "0x2222222222222222222222222222222222222222"

function provider(): EthereumProvider {
  return {request: vi.fn(async () => undefined)}
}

beforeEach(() => {
  vi.stubGlobal("window", {location: {origin: "https://regents.sh"}})
  replaceConnectedEthereumWallets([])
  replaceActiveEthereumWallet(null)
})

afterEach(() => vi.unstubAllGlobals())

describe("P1_ACTIVE_WALLET_ONLY: Privy's selection is the Stake wallet", () => {
  it("publishes the selected wallet under its lowercased address", () => {
    const selected = provider()
    replaceActiveEthereumWallet({address: first.toUpperCase(), provider: selected})

    expect(activeEthereumWallet()).toEqual({address: first, provider: selected})

    replaceActiveEthereumWallet(null)
    expect(activeEthereumWallet()).toBeNull()
  })

  it("accepts only an Ethereum selection that is still connected", () => {
    const wallets = [{address: first}, {address: second}]

    expect(eligibleActiveWallet({address: second, type: "ethereum"}, wallets)).toEqual({
      address: second,
      type: "ethereum",
    })

    // A Solana selection, an absent one, and one the provider has dropped are
    // each no wallet at all rather than a reason to pick a different one.
    expect(eligibleActiveWallet({address: second, type: "solana"}, wallets)).toBeNull()
    expect(eligibleActiveWallet(undefined, wallets)).toBeNull()
    expect(eligibleActiveWallet(null, wallets)).toBeNull()
    expect(
      eligibleActiveWallet({address: "0x3333333333333333333333333333333333333333", type: "ethereum"}, wallets),
    ).toBeNull()
    expect(eligibleActiveWallet({address: second, type: "ethereum"}, [])).toBeNull()
  })

  // Redeem and Autolaunch keep reading the connected set by expected signer.
  // Publishing an active wallet changes neither answer.
  it("leaves the shared connected-wallet lookup untouched", () => {
    const one = provider()
    const two = provider()
    replaceConnectedEthereumWallets([
      [first, one],
      [second, two],
    ])
    replaceActiveEthereumWallet({address: second, provider: two})

    expect(connectedEthereumWallet(first)?.provider).toBe(one)
    expect(connectedEthereumWallet(second)?.provider).toBe(two)
    expect(connectedEthereumWallet()?.provider).toBe(one)
    expect(connectedEthereumWallet("0x3333333333333333333333333333333333333333")).toBeNull()
  })

  it("has no active wallet before the bridge publishes one", () => {
    replaceConnectedEthereumWallets([[first, provider()]])

    expect(activeEthereumWallet()).toBeNull()
  })
})
