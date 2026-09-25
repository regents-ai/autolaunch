import type {Address, Hex} from "viem"

import type {Hook} from "../hook_composition"
import {builtFor, formOnScreen, type BidInputs} from "./bid_form_on_screen"
import {reportBrowserWallets} from "./browser_wallets"
import {connectedEthereumWallet, signerWalletOrConnect} from "../wallet_actions/connected_wallet"
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
  // A bid review carries the form values it was built for; one answering a
  // press names the step that press sends.
  inputs?: BidInputs
  send?: string
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
  stopReporting?: () => void
  clicked?: (event: Event) => void
}

export const AutolaunchReviewedSteps: Hook = {
  mounted(this: ReviewedStepsHook) {
    // Pool data arrives after navigation; the #stake target may not have existed yet.
    if (this.el.hasAttribute("data-stake-panel") && window.location.hash === "#stake") {
      this.el.scrollIntoView({block: "start"})
    }
    const push = (event: string, payload: unknown) => this.pushEventTo(this.el, event, payload)
    const mine = (payload: unknown) =>
      (payload as {component_id?: string} | null)?.component_id === this.el.id

    this.review = null
    this.stopReporting = reportBrowserWallets(push)

    this.handleEvent("reviewed-steps:review", payload => {
      if (!mine(payload)) return
      const review = payload as Review
      this.review = review
      if (review.send) void send(this.el, review, review.send, push)
    })
    this.handleEvent("reviewed-steps:cleared", payload => {
      if (mine(payload)) this.review = null
    })
    // Sent after the page shows the new figures, so the box they land in is
    // focused only once it holds them.
    this.handleEvent("reviewed-steps:focus", payload => {
      if (!mine(payload)) return
      document.getElementById((payload as {to: string}).to)?.focus()
    })

    this.clicked = (event: Event) => {
      const target = event.target as HTMLElement | null
      const name = target?.closest<HTMLElement>("[data-reviewed-step]")?.dataset.reviewedStep
      if (!name) return

      // A panel with a bid form on screen sends only a review built for the
      // values shown right now; otherwise the server builds one and sends it.
      const form = formOnScreen(this.el)
      if (form && !builtFor(this.review?.inputs, form)) push("prepare_and_send", {form})
      else void send(this.el, this.review ?? null, name, push)
    }
    this.el.addEventListener("click", this.clicked)
  },

  destroyed(this: ReviewedStepsHook) {
    if (this.clicked) this.el.removeEventListener("click", this.clicked)
    this.stopReporting?.()
  },
}

// Every press reaches the wallet. It sends from the review's signer, the
// signed-in wallet, as this tab has it connected; when it is not connected here,
// the press opens Privy's connect step instead and nothing is sent. The hash is
// reported and nothing is read afterwards: the server owns every question about
// what that hash did. While a press is with the wallet the panel is only marked,
// never locked.
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
    if (!signerWalletOrConnect(review.signer)) throw new Error("The signed-in wallet is not connected here.")

    // A panel that prepares its review again in the background keeps this one
    // while the wallet has it, so the sent step is checked against it.
    if (el.dataset.reportsOpening !== undefined) push("step_opening", {step: name})

    const transaction_hash = await sendLabTransaction(
      review,
      {to: step.to, data: step.data},
      () => connectedEthereumWallet(review.signer),
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
