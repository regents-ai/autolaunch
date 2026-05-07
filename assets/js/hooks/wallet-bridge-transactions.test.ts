import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { walletActionNetworkSwitchMessage } from "./wallet-bridge-network.ts"

describe("walletActionNetworkSwitchMessage", () => {
  it("names Base mainnet for Regent staking actions", () => {
    assert.equal(
      walletActionNetworkSwitchMessage(8453),
      "Switch your wallet to Base mainnet before continuing.",
    )
  })

  it("names Base Sepolia for launch wallet actions", () => {
    assert.equal(
      walletActionNetworkSwitchMessage(84532),
      "Switch your wallet to the Base Sepolia network before continuing.",
    )
  })
})
