// Invariant (Sean, 21 Oct 2026): a sign-in shows only its own account's wallets,
// so a wallet app left connected from before never acts for the account.
import {expect, it} from "vitest"

import {accountActiveWallet} from "../js/wallet_actions/connected_wallet"

const zerion = {address: "0x0cB2000000000000000000000000000000003C37", type: "ethereum"}
const regents = {address: "0x2c95000000000000000000000000000000008cf6", type: "ethereum"}
const held = [zerion, regents]

it("signed in, a wallet app left from before is never the account's wallet", () => {
  expect(accountActiveWallet(zerion, held, true, [regents.address])).toBeNull()
  expect(accountActiveWallet(regents, held, true, [regents.address])).toBe(regents)
  expect(accountActiveWallet(zerion, held, true, [zerion.address.toLowerCase()])).toBe(zerion)
  expect(accountActiveWallet(zerion, held, false, [])).toBe(zerion)
  expect(accountActiveWallet(zerion, [regents], false, [])).toBeNull()
  expect(accountActiveWallet({...regents, type: "solana"}, held, true, [regents.address])).toBeNull()
})
