import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { stakingActionNeedsWalletConfirmation } from "./regent-staking-session.ts"

describe("stakingActionNeedsWalletConfirmation", () => {
  it("requires connection when the wallet is signed out", () => {
    assert.equal(
      stakingActionNeedsWalletConfirmation({
        authenticated: false,
        account: null,
        walletClient: null,
      }),
      true,
    )
  })

  it("requires connection when the wallet client is not ready", () => {
    assert.equal(
      stakingActionNeedsWalletConfirmation({
        authenticated: true,
        account: "0x1111111111111111111111111111111111111111",
        walletClient: null,
      }),
      true,
    )
  })

  it("allows a ready wallet session", () => {
    assert.equal(
      stakingActionNeedsWalletConfirmation({
        authenticated: true,
        account: "0x1111111111111111111111111111111111111111",
        walletClient: {},
      }),
      false,
    )
  })
})
