import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {
  sendSubjectStep,
  sendableStep,
  userRejected,
  type SubjectWalletOperation,
} from "../wallet_actions/autolaunch_subject_wallet"

const pendingKey = "regent:autolaunch-subject-wallet:open"
const hashKey = "regent:autolaunch-subject-wallet:hash"

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

type SubjectWalletHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  publishActiveWallet?: () => void
}

export const AutolaunchSubjectWallet: Hook = {
  mounted(this: SubjectWalletHook) {
    let operation: SubjectWalletOperation | null = null

    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    const failed = (reason: FailureReason) => push("subject_wallet_failed", {reason})

    // Privy's selection is what this surface reads, so every change is
    // republished and the server decides what that wallet is allowed to see.
    this.publishActiveWallet = () =>
      push("subject_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()

    if (stored(sessionStorage, pendingKey)) push("restore_subject_wallet_operation", {})

    // A callback lost to a reload, a reconnect or a reauthentication: the hash is
    // replayed until the server says that exact hash is durable. Nothing is
    // resent, because a hash is all this ever reports.
    const retained = retainedHash(sessionStorage)
    if (retained) push("subject_wallet_submitted", retained)

    this.handleEvent("autolaunch-subject-wallet:operation", payload => {
      operation = payload as SubjectWalletOperation
      rememberOperation(operation, sessionStorage)
    })

    this.handleEvent("autolaunch-subject-wallet:cleared", () => {
      operation = null
      forget(sessionStorage, pendingKey)
    })

    this.handleEvent("autolaunch-subject-wallet:hash-durable", durable =>
      releaseHash(durable, sessionStorage),
    )

    // A claim is only asked for once the wallet in front of the customer really
    // is the reviewed signer. A negative preflight asks for nothing at all.
    this.el.addEventListener("click", async event => {
      const target = (event.target as HTMLElement | null) ?? null

      if (target?.closest("[data-subject-wallet-connect]")) {
        window.dispatchEvent(new CustomEvent("autolaunch:wallet-connect"))
        return
      }

      const confirm = target?.closest<HTMLElement>("[data-subject-wallet-send]")
      const actionId = confirm?.dataset.subjectWalletSend
      const signer = confirm?.dataset.subjectWalletSigner
      if (!actionId || !signer) return

      if (await activeSigner(signer)) push("sign_subject_wallet_step", {"action-id": actionId})
      else failed("wallet_unavailable")
    })

    this.handleEvent("autolaunch-subject-wallet:send", async payload => {
      const {action_id: actionId, step: stepName} = payload as {action_id: string; step: string}
      const held = operation
      if (!held) return

      // The claim is already durable, so a failure below the send marker is proof
      // the wallet was never asked for anything: the exact step is released and
      // the same review stays sendable.
      let sendStarted = false
      const notStarted = () => push("subject_wallet_dispatch_not_started", {action_id: actionId})

      try {
        const step = sendableStep(held, actionId, stepName)
        const connected = activeEthereumWallet()
        if (!connected || !(await activeSigner(held.signer))) {
          notStarted()
          return
        }

        const hash = await sendSubjectStep(
          held,
          step,
          connected.provider,
          () => (sendStarted = true),
        )

        // Retained synchronously, before the one callback: a reload between the
        // send and the report must not lose the only record of this hash. The
        // browser then reports it once and stops; it never decides an outcome.
        const reported = {action_id: actionId, step: step.step, transaction_hash: hash}
        retainHash(reported, sessionStorage)
        push("subject_wallet_submitted", reported)
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
          push("subject_wallet_rejected", {action_id: actionId, code: 4001})
          return
        }

        failed("send_unconfirmed")
      }
    })
  },

  destroyed(this: SubjectWalletHook) {
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
  const active = activeEthereumWallet()
  if (!active || !sameHex(active.address, expectedSigner)) return null

  const accounts = await active.provider.request({method: "eth_accounts"}).catch(() => null)
  const [account] = Array.isArray(accounts) ? accounts : []
  return typeof account === "string" && sameHex(account, expectedSigner) ? active.address : null
}

/**
 * The recovery hint, and only that: the identity of an operation a reload should
 * ask the server about. No transaction, signer, calldata or outcome is ever
 * restored from here, and a terminal operation leaves nothing behind.
 */
export function rememberOperation(
  operation: SubjectWalletOperation,
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
