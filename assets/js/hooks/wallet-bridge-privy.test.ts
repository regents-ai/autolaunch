import assert from "node:assert/strict"
import { describe, it } from "node:test"

import {
  accountFromAccountsChanged,
  resolvePrivyChainId,
  selectPrivyEthereumWallet,
} from "./wallet-bridge-privy.ts"

describe("resolvePrivyChainId", () => {
  it("accepts numeric chain ids", () => {
    assert.equal(resolvePrivyChainId(8453), 8453)
  })

  it("accepts decimal string chain ids", () => {
    assert.equal(resolvePrivyChainId("8453"), 8453)
  })

  it("accepts eip155 chain ids", () => {
    assert.equal(resolvePrivyChainId("eip155:8453"), 8453)
  })

  it("returns null for missing or invalid chain ids", () => {
    assert.equal(resolvePrivyChainId(null), null)
    assert.equal(resolvePrivyChainId("base"), null)
  })
})

describe("accountFromAccountsChanged", () => {
  it("normalizes the first wallet account", () => {
    assert.equal(
      accountFromAccountsChanged(["0xAaaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa"]),
      "0xAaaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa",
    )
  })

  it("rejects empty account events", () => {
    assert.equal(accountFromAccountsChanged([]), null)
    assert.equal(accountFromAccountsChanged("0xabc"), null)
  })
})

describe("selectPrivyEthereumWallet", () => {
  it("prefers the active embedded wallet when it is valid", async () => {
    const activeWallet = {
      type: "ethereum",
      address: "0x1111111111111111111111111111111111111111",
      walletClientType: "privy",
      getEthereumProvider: async () => ({}),
    }

    assert.equal(
      selectPrivyEthereumWallet({
        activeWallet,
        wallets: [],
        privyUserAddress: "0x2222222222222222222222222222222222222222",
      }),
      activeWallet,
    )
  })

  it("falls back to the wallet that matches the Privy user address", async () => {
    const matchingWallet = {
      type: "ethereum",
      address: "0x2222222222222222222222222222222222222222",
      getEthereumProvider: async () => ({}),
    }

    assert.equal(
      selectPrivyEthereumWallet({
        activeWallet: null,
        wallets: [
          {
            type: "ethereum",
            address: "0x1111111111111111111111111111111111111111",
            getEthereumProvider: async () => ({}),
          },
          matchingWallet,
        ],
        privyUserAddress: "0x2222222222222222222222222222222222222222",
      }),
      matchingWallet,
    )
  })
})
