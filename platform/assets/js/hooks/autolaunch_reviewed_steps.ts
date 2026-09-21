import type {Address, Hex} from "viem"

import type {Hook} from "../hook_composition"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {userRejected} from "../wallet_actions/autolaunch_launch"
import {
  LabNetworkMismatch,
  sendLabTransaction,
  type AutolaunchLabAnchor,
  type AutolaunchLabBinding,
} from "../wallet_actions/autolaunch_network"

/**
 * One server-reviewed sequence, exactly as the server wrote it. The browser
 * holds it only to hand a named step to the wallet: there is no encoder here,
 * and nothing about a sent step is remembered past this page.
 */
type Review = {
  component_id: string
  signer: Address
  chain_id: number
  lab: AutolaunchLabBinding
  lab_anchor: AutolaunchLabAnchor
  steps: {step: string; to: Address; data: Hex}[]
}

// `wallet_unavailable` and `network_mismatch` are the reasons that prove nothing was sent.
type FailureReason =
  | "wallet_unavailable"
  | "network_mismatch"
  | "wallet_declined"
  | "send_unconfirmed"

type ReviewedStepsHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  review?: Review | null
  publishActiveWallet?: () => void
  clicked?: (event: Event) => void
}

export const AutolaunchReviewedSteps: Hook = {
  mounted(this: ReviewedStepsHook) {
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    const mine = (payload: unknown) =>
      (payload as {component_id?: string} | null)?.component_id === this.el.id

    this.review = null
    this.publishActiveWallet = () =>
      push("active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    this.publishActiveWallet()

    this.handleEvent("reviewed-steps:review", payload => {
      if (mine(payload)) this.review = payload as Review
    })
    this.handleEvent("reviewed-steps:cleared", payload => {
      if (mine(payload)) this.review = null
    })

    this.clicked = (event: Event) => {
      const target = event.target as HTMLElement | null

      if (target?.closest("[data-wallet-connect]")) {
        window.dispatchEvent(new CustomEvent("autolaunch:wallet-connect"))
        return
      }

      const name = target?.closest<HTMLElement>("[data-reviewed-step]")?.dataset.reviewedStep
      if (name) void send(this.el, this.review ?? null, name, push)
    }
    this.el.addEventListener("click", this.clicked)
  },

  destroyed(this: ReviewedStepsHook) {
    if (this.clicked) this.el.removeEventListener("click", this.clicked)
    if (this.publishActiveWallet) {
      window.removeEventListener("autolaunch:wallet-state", this.publishActiveWallet)
    }
  },
}

// Every press reaches the wallet. The hash is reported and nothing is read
// afterwards: the server owns every question about what that hash did. While a
// press is with the wallet the panel is only marked, never locked.
async function send(
  el: HTMLElement,
  review: Review | null,
  name: string,
  push: (event: string, payload: unknown) => void,
): Promise<void> {
  const step = review?.steps.find(candidate => candidate.step === name)
  let started = false

  el.dataset.awaitingWallet = name

  try {
    if (!review || !step) throw new Error("This step is not part of the review.")

    const transaction_hash = await sendLabTransaction(
      review,
      {to: step.to, data: step.data},
      () => activeEthereumWallet(),
      () => {
        started = true
      },
    )

    push("step_sent", {step: name, transaction_hash})
  } catch (error) {
    push("step_failed", {step: name, reason: failure(started, error)})
  } finally {
    if (el.dataset.awaitingWallet === name) delete el.dataset.awaitingWallet
  }
}

function failure(started: boolean, error: unknown): FailureReason {
  if (!started) return error instanceof LabNetworkMismatch ? "network_mismatch" : "wallet_unavailable"
  return userRejected(error) ? "wallet_declined" : "send_unconfirmed"
}
