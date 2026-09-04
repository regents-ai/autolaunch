import type {Hook} from "../hook_composition"
import {
  activeEthereumWallet,
  type SelectedWallet,
} from "../wallet_actions/connected_wallet"
import {
  sendBidStep,
  sendableStep,
  userRejected,
  type BidOperation,
} from "../wallet_actions/autolaunch_bids"

const pendingKey = "regent:autolaunch-bid:open"
const hashKey = "regent:autolaunch-bid:hash"

// The closed set of failures this surface can describe. Provider, viem, revert
// and wallet-vendor text is never a customer message, so it is never sent.
// `wallet_unavailable` is the only one that proves nothing was sent.
type FailureReason = "wallet_unavailable" | "send_unconfirmed"

/** The one transaction this browser reported, as it reported it. */
export type ReportedHash = {
  action_id: string
  step: string
  transaction_hash: string
}

type BidHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  publishActiveWallet?: () => void
}

export const AutolaunchBidWallet: Hook = {
  mounted(this: BidHook) {
    let operation: BidOperation | null = null

    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    const failed = (reason: FailureReason) => push("bid_wallet_failed", {reason})

    // Privy's selection is what the bidder reads, so every change is republished
    // and the server decides what that wallet is allowed to see.
    this.publishActiveWallet = () =>
      push("bid_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()

    if (stored(sessionStorage, pendingKey)) push("restore_bid_operation", {})

    // A callback lost to a reload, a reconnect or a reauthentication: the hash
    // is replayed until the server says that exact hash is durable. Nothing is
    // resent, because a hash is all this ever reports.
    const retained = retainedHash(sessionStorage)
    if (retained) push("bid_submitted", retained)

    this.handleEvent("autolaunch-bid:operation", payload => {
      operation = payload as BidOperation
      rememberOperation(operation, sessionStorage)
    })

    this.handleEvent("autolaunch-bid:cleared", () => {
      operation = null
      forget(sessionStorage, pendingKey)
    })

    this.handleEvent("autolaunch-bid:hash-durable", durable => releaseHash(durable, sessionStorage))

    // A claim is only asked for once the wallet in front of the customer really
    // is the reviewed signer. A negative preflight asks for nothing at all.
    this.el.addEventListener("click", async event => {
      const target = (event.target as HTMLElement | null) ?? null

      if (target?.closest("[data-bid-connect]")) {
        window.dispatchEvent(new CustomEvent("autolaunch:wallet-connect"))
        return
      }

      const confirm = target?.closest<HTMLElement>("[data-bid-send]")
      const actionId = confirm?.dataset.bidSend
      const signer = confirm?.dataset.bidSigner
      if (!actionId || !signer) return

      if (await activeSigner(signer)) push("sign_bid_step", {"action-id": actionId})
      else failed("wallet_unavailable")
    })

    this.handleEvent("autolaunch-bid:send", async payload => {
      const {action_id: actionId, step: stepName} = payload as {action_id: string; step: string}
      const held = operation
      if (!held) return

      // The claim is already durable, so a failure below the send marker is
      // proof the wallet was never asked for anything: the exact step is
      // released and the same review stays sendable.
      let sendStarted = false
      const notStarted = () => push("bid_dispatch_not_started", {action_id: actionId})

      try {
        const step = sendableStep(held, actionId, stepName)
        if (!(await activeWalletForSigner(held.signer))) {
          notStarted()
          return
        }

        const hash = await sendBidStep(
          held,
          step,
          activeEthereumWallet,
          () => (sendStarted = true),
        )

        // Retained synchronously, before the one callback: a reload between the
        // send and the report must not lose the only record of this hash. The
        // browser then reports it once and stops; it never decides an outcome.
        const reported = {action_id: actionId, step: step.step, transaction_hash: hash}
        retainHash(reported, sessionStorage)
        push("bid_submitted", reported)
      } catch (error) {
        if (!sendStarted) {
          notStarted()
          return
        }

        // A rejection of the transaction request itself, reported unconditionally:
        // browser state is evidence, never authority. The database refuses to
        // close a step once a hash is bound, so withholding this would only
        // strand a claim the server can no longer end.
        if (userRejected(error)) {
          push("bid_wallet_rejected", {action_id: actionId, code: 4001})
          return
        }

        failed("send_unconfirmed")
      }
    })
  },

  destroyed(this: BidHook) {
    if (this.publishActiveWallet) {
      window.removeEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    }
  },
}

/**
 * The active wallet's own address when both the Privy selection and the
 * provider's current account are exactly the reviewed signer, or `null`.
 * A missing provider, a refused read and a changed account are all `null`.
 */
export async function activeSigner(expectedSigner: string): Promise<string | null> {
  return (await activeWalletForSigner(expectedSigner))?.address ?? null
}

async function activeWalletForSigner(expectedSigner: string): Promise<SelectedWallet | null> {
  const active = activeEthereumWallet()
  if (!active || !sameHex(active.address, expectedSigner)) return null

  const accounts = await active.provider.request({method: "eth_accounts"}).catch(() => null)
  const [account] = Array.isArray(accounts) ? accounts : []
  return typeof account === "string" && sameHex(account, expectedSigner) ? active : null
}

/**
 * The recovery hint, and only that: the identity of an operation a reload should
 * ask the server about. No transaction, signer or outcome is ever restored from
 * here, and a terminal operation leaves nothing behind.
 */
export function rememberOperation(
  operation: BidOperation,
  storage: Pick<Storage, "setItem" | "removeItem">,
): void {
  try {
    if (operation.terminal) storage.removeItem(pendingKey)
    else storage.setItem(pendingKey, operation.action_id)
  } catch {
    // The connected LiveView already holds the operation; this is refresh only.
  }
}

/** Keeps a reported hash so a lost callback can be replayed rather than resent. */
export function retainHash(reported: ReportedHash, storage: Pick<Storage, "setItem">): void {
  try {
    storage.setItem(hashKey, JSON.stringify(reported))
  } catch {
    // A browser refusing storage keeps its connected LiveView and nothing else.
  }
}

/** Whatever this browser last reported, if it is still a whole report. */
export function retainedHash(storage: Pick<Storage, "getItem">): ReportedHash | null {
  const held = stored(storage, hashKey)
  if (!held) return null

  try {
    const parsed: unknown = JSON.parse(held)
    return whole(parsed) ? parsed : null
  } catch {
    return null
  }
}

/** Drops the retained report only for the exact hash the server acknowledged. */
export function releaseHash(
  durable: unknown,
  storage: Pick<Storage, "getItem" | "removeItem">,
): void {
  const held = retainedHash(storage)
  if (!held || !whole(durable) || !sameReport(held, durable)) return

  forget(storage, hashKey)
}

function whole(value: unknown): value is ReportedHash {
  if (typeof value !== "object" || value === null) return false

  const {action_id: id, step, transaction_hash: hash} = value as Partial<ReportedHash>
  return typeof id === "string" && typeof step === "string" && typeof hash === "string"
}

function sameReport(left: ReportedHash, right: ReportedHash): boolean {
  return (
    left.action_id === right.action_id &&
    left.step === right.step &&
    sameHex(left.transaction_hash, right.transaction_hash)
  )
}

function stored(storage: Pick<Storage, "getItem">, key: string): string | null {
  try {
    return storage.getItem(key)
  } catch {
    return null
  }
}

function forget(storage: Pick<Storage, "removeItem">, key: string): void {
  try {
    storage.removeItem(key)
  } catch {
    // There is nothing to forget in a browser that refuses storage at all.
  }
}

function sameHex(left: string, right: string): boolean {
  return left.toLowerCase() === right.toLowerCase()
}
