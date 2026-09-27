import type {Address} from "viem"

import type {Hook} from "../hook_composition"
import {agentCard, type AgentCardHandle} from "../agent_wallet_tools"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {failure, NothingSent, sendStep, type Failure, type Step, type StepChain} from "../wallet_actions/send_step"

/**
 * Who sends, on which chain, the steps the buttons name, and the on-screen
 * inputs they were built from, all on the server. It never changes: a new
 * figure is a new review with a new id.
 */
export type Review = {
  id: string
  component_id: string
  signer: Address
  chain: StepChain
  steps: Step[]
  inputs: Record<string, string>
}

/** What the wallet answered one press: the hash, or why nothing was sent. */
export type Pressed = {transaction_hash: string} | {reason: Failure}

type Push = (event: string, payload: unknown) => void

type OnchainStepsHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload?: unknown): Promise<PromiseSettledResult<{reply: unknown}>[]>
  review?: Review
  agent?: AgentCardHandle
  clicked?: (event: Event) => void
  walletChanged?: () => void
}

// How many of a button's presses the wallet still has. The mark comes off when
// the last one is answered.
const presses = new WeakMap<HTMLElement, number>()

/**
 * The wallet buttons of one server component. The component's root carries the
 * hook and a DOM id; each button names its step with `data-onchain-step`, and
 * each form field the review depends on is marked `data-onchain-input="name"`.
 * A card that answers agent tools names them in `data-agent-tools`.
 */
export const OnchainSteps: Hook = {
  mounted(this: OnchainStepsHook) {
    // Pool data arrives after navigation; the #stake target may not have existed yet.
    if (this.el.hasAttribute("data-stake-panel") && window.location.hash === "#stake") {
      this.el.scrollIntoView({block: "start"})
    }
    const push: Push = (event, payload) => void this.pushEventTo(this.el, event, payload)

    // Every hook on the page hears this event; keep only this component's review.
    // No review means no eligible wallet: a press then sends nothing.
    this.handleEvent("onchain-steps:review", payload => {
      const {component_id, review} = payload as {component_id: string; review: Review | null}
      if (component_id === this.el.id) this.review = review ?? undefined
    })

    // The server asks for Privy's connect step when a review needs a wallet
    // and none is active in this tab.
    this.handleEvent("onchain-steps:connect", payload => {
      if ((payload as {component_id: string}).component_id === this.el.id) {
        window.dispatchEvent(new CustomEvent("autolaunch:wallet-connect"))
      }
    })

    this.agent = agentCard(this, (review, name) => press(review, name, push))

    // Every press runs on its own and reaches the wallet, even while an earlier
    // one is still there. On a card with review inputs, a press with no review
    // yet, or whose review no longer matches the form on screen, asks the
    // server for the matching review and sends what comes back.
    this.clicked = event => {
      const button = (event.target as Element | null)?.closest<HTMLElement>("[data-onchain-step]")
      const name = button?.dataset.onchainStep
      if (!button || !name || !this.el.contains(button)) return
      const release = mark(button)
      const form = formInputs(this.el)

      const asks = Object.keys(form).length > 0 && (!this.review || !sameInputs(this.review.inputs, form))
      if (activeEthereumWallet() && asks) {
        void this.pushEventTo(this.el, "prepare_and_send", {form, step: name})
          .then(([result]) => {
            const reply = result?.status === "fulfilled" ? result.value.reply as {review?: Review; send?: string} : {}
            if (reply.review && reply.send) return press(reply.review, reply.send, push)
            push("step_failed", {step: name, reason: "step_unknown"})
          })
          // A lost connection drops the question; the button comes back to press again.
          .catch(() => {})
          .finally(release)
      } else {
        void press(this.review, name, push).finally(release)
      }
    }
    this.el.addEventListener("click", this.clicked)

    // The server decides which wallet may act; it hears every change of the
    // wallet Privy has active and pushes a new review, or none.
    this.walletChanged = () => push("onchain_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("autolaunch:wallet-state", this.walletChanged)
    this.walletChanged()
  },

  disconnected(this: OnchainStepsHook) {
    this.agent?.disconnected()
  },

  destroyed(this: OnchainStepsHook) {
    if (this.clicked) this.el.removeEventListener("click", this.clicked)
    if (this.walletChanged) window.removeEventListener("autolaunch:wallet-state", this.walletChanged)
    this.agent?.dispose()
  },
}

/**
 * Sends the named step from Privy's active wallet, the only wallet that acts,
 * when it is the signer the server built the review for. With no wallet
 * active, the press opens the connect step and sends nothing. Reports only what
 * the wallet answered, against the review it sent from: the hash, or why
 * nothing was sent. The server decides what the hash did.
 */
export async function press(review: Review | undefined, name: string, push: Push): Promise<Pressed> {
  const step = review?.steps.find(candidate => candidate.step === name)
  let sending = false
  const started = () => {
    sending = true
  }

  try {
    if (!activeEthereumWallet()) {
      window.dispatchEvent(new CustomEvent("autolaunch:wallet-connect"))
      throw new NothingSent("wallet_unavailable")
    }
    if (!review || !step) throw new NothingSent("step_unknown")
    const wallet = () => {
      const active = activeEthereumWallet()
      return active?.address.toLowerCase() === review.signer.toLowerCase() ? active : null
    }
    if (!wallet()) throw new NothingSent("wallet_unavailable")

    const transaction_hash = await sendStep(review.chain, review.signer, step, wallet, started)
    push("step_sent", {review_id: review.id, step: name, transaction_hash})
    return {transaction_hash}
  } catch (error) {
    const reason = failure(sending, error)
    push("step_failed", {step: name, reason})
    return {reason}
  }
}

/**
 * The review's inputs as they are on screen now: text as typed, a box as
 * "true" or "false", and a group of choices as the one chosen.
 */
export function formInputs(root: HTMLElement): Record<string, string> {
  const inputs: Record<string, string> = {}
  root.querySelectorAll<HTMLInputElement | HTMLSelectElement>("[data-onchain-input]").forEach(input => {
    const name = input.dataset.onchainInput
    if (!name) return
    if (input instanceof HTMLInputElement && input.type === "radio") {
      if (input.checked) inputs[name] = input.value
    } else {
      inputs[name] = input instanceof HTMLInputElement && input.type === "checkbox" ? String(input.checked) : input.value
    }
  })
  return inputs
}

function sameInputs(review: Record<string, string>, form: Record<string, string>): boolean {
  const names = new Set([...Object.keys(review), ...Object.keys(form)])
  return [...names].every(name => review[name] === form[name])
}

// Marked with a data attribute and CSS only: the button keeps taking presses.
function mark(button: HTMLElement): () => void {
  presses.set(button, (presses.get(button) ?? 0) + 1)
  button.dataset.awaitingWallet = "true"

  return () => {
    const left = (presses.get(button) ?? 1) - 1
    presses.set(button, left)
    if (left <= 0) delete button.dataset.awaitingWallet
  }
}
