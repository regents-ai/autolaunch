import type {Address} from "viem"

import type {Hook} from "../hook_composition"
import {report} from "../visit_log"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import type {EthereumProvider} from "../wallet_actions/connected_wallet"
import {
  failure,
  landedCalls,
  NothingSent,
  refusedAtomic,
  sendsAtomically,
  sendStep,
  sendSteps,
  type Failure,
  type Step,
  type StepChain,
} from "../wallet_actions/send_step"

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

/** What the wallet answered a press that sends every step at once: its id for the batch, or why nothing was sent. */
export type PressedCalls = {calls_id: string} | {reason: Failure}

type Push = (event: string, payload: unknown) => void

type OnchainStepsHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload?: unknown): Promise<PromiseSettledResult<{reply: unknown}>[]>
  review?: Review
  clicked?: (event: Event) => void
  walletChanged?: () => void
  refresh?: () => void
  leaving?: AbortController
}

// How many of a button's presses the wallet still has. The mark comes off when
// the last one is answered.
const presses = new WeakMap<HTMLElement, number>()

/**
 * The wallet buttons of one server component. The component's root carries the
 * hook and a DOM id; each button names its step with `data-onchain-step`, and
 * each form field the review depends on is marked `data-onchain-input="name"`.
 *
 * A root marked `data-onchain-bundle` asks the wallet, for each review of
 * several steps, whether it can send them together atomically on the review's
 * chain, and tells the server (`onchain_atomic`). The server then shows one
 * button marked `data-onchain-bundle`, whose press sends every step in one
 * `wallet_sendCalls` request, or the steps one at a time as before.
 *
 * A root marked `data-refresh-funds` also asks the server to read its funds
 * again (`refresh_funds`) when the wallet changes, when the page comes back
 * into view, when the window holding it opens (`autolaunch:refresh-funds` on
 * the root) and after each press.
 */
export const OnchainSteps: Hook = {
  mounted(this: OnchainStepsHook) {
    // Pool data arrives after navigation, so a link to the token page's trade
    // widget is scrolled to once its staking part is on the page.
    if (this.el.hasAttribute("data-stake-panel") && window.location.hash === "#trade") {
      this.el.closest("#trade")?.scrollIntoView({block: "start"})
    }
    const push: Push = (event, payload) => void this.pushEventTo(this.el, event, payload)
    // Ends the wait for a sent batch's status when the panel leaves the page.
    this.leaving = new AbortController()

    // Every hook on the page hears this event; keep only this component's review.
    // No review means no eligible wallet: a press then sends nothing.
    this.handleEvent("onchain-steps:review", payload => {
      const {component_id, review} = payload as {component_id: string; review: Review | null}
      if (component_id !== this.el.id) return
      this.review = review ?? undefined
      if (review && review.steps.length > 1 && this.el.hasAttribute("data-onchain-bundle")) {
        void atomically(review).then(atomic => {
          if (this.review?.id === review.id) push("onchain_atomic", {review_id: review.id, atomic})
        })
      }
    })

    // Every press runs on its own and reaches the wallet, even while an earlier
    // one is still there. On a card with review inputs, a press with no review
    // yet, or whose review no longer matches the form on screen, asks the
    // server for the matching review and sends what comes back.
    this.clicked = event => {
      const button = (event.target as Element | null)?.closest<HTMLElement>("[data-onchain-step], [data-onchain-bundle]")
      if (!button || card(button) !== this.el) return
      if (button.hasAttribute("data-onchain-bundle")) {
        const marked = mark(button)
        void pressCalls(this.review, push, this.leaving!.signal).finally(marked)
        return
      }
      const name = button.dataset.onchainStep
      if (!name) return
      const marked = mark(button)
      // The press may have spent funds or changed what the wallet allows.
      const release = () => {
        marked()
        this.refresh?.()
      }
      const form = formInputs(this.el)
      lost(this.el, false)
      // The server never heard the press, so it cannot say why; the page does, and
      // reports it.
      const unheard = () => {
        lost(this.el, true)
        report({name: "press.unsent", where: name, outcome: "lost"})
      }

      const asks = Object.keys(form).length > 0 && (!this.review || !sameInputs(this.review.inputs, form))
      if (activeEthereumWallet() && asks) {
        void this.pushEventTo(this.el, "prepare_and_send", {form, step: name})
          .then(async ([result]) => {
            if (result?.status !== "fulfilled") return unheard()
            const reply = result.value.reply as {review?: Review; send?: string}
            if (reply.review && reply.send) await press(reply.review, reply.send, push)
            else push("step_failed", {step: name, reason: "step_unknown"})
          })
          .catch(unheard)
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

    if (this.el.hasAttribute("data-refresh-funds")) {
      this.refresh = () => push("refresh_funds", {})
      window.addEventListener("autolaunch:wallet-state", this.refresh)
      window.addEventListener("focus", this.refresh)
      this.el.addEventListener("autolaunch:refresh-funds", this.refresh)
    }

    this.walletChanged()
    this.refresh?.()
  },

  destroyed(this: OnchainStepsHook) {
    this.leaving?.abort()
    if (this.clicked) this.el.removeEventListener("click", this.clicked)
    if (this.walletChanged) window.removeEventListener("autolaunch:wallet-state", this.walletChanged)
    if (this.refresh) {
      window.removeEventListener("autolaunch:wallet-state", this.refresh)
      window.removeEventListener("focus", this.refresh)
      this.el.removeEventListener("autolaunch:refresh-funds", this.refresh)
    }
  },
}

/**
 * Sends the named step from Privy's active wallet, the only wallet that acts,
 * when it is the signer the server built the review for. With no wallet
 * active, or another one, the press sends nothing. Reports only what
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
    if (!activeEthereumWallet()) throw new NothingSent("wallet_unavailable")
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
 * Sends every step of the review in one atomic batch from Privy's active
 * wallet, when it is the review's signer, and reports the wallet's id for it.
 * The wallet's own report on the batch is then awaited without holding the
 * press: the one transaction its receipts name goes to the server, which reads
 * it itself. A wallet that refuses to send the calls atomically sends nothing,
 * and the server goes back to one step at a time.
 */
export async function pressCalls(
  review: Review | undefined,
  push: Push,
  leaving: AbortSignal = new AbortController().signal,
): Promise<PressedCalls> {
  let sending = false
  const started = () => {
    sending = true
  }

  try {
    if (!activeEthereumWallet()) throw new NothingSent("wallet_unavailable")
    if (!review) throw new NothingSent("step_unknown")
    const wallet = () => {
      const active = activeEthereumWallet()
      return active?.address.toLowerCase() === review.signer.toLowerCase() ? active : null
    }
    const sender = wallet()
    if (!sender) throw new NothingSent("wallet_unavailable")

    const calls_id = await sendSteps(review.chain, review.signer, review.steps, wallet, started)
    push("calls_sent", {review_id: review.id, calls_id})
    void followCalls(review, sender.provider, calls_id, push, leaving)
    return {calls_id}
  } catch (error) {
    if (review && sending && refusedAtomic(error)) {
      push("onchain_atomic", {review_id: review.id, atomic: false})
      push("step_failed", {step: "calls", reason: "step_unknown"})
      return {reason: "step_unknown"}
    }
    const reason = failure(sending, error)
    push("step_failed", {step: "calls", reason})
    return {reason}
  }
}

// The wallet's report on a batch it took: the one transaction it landed in,
// that it sent nothing, or no final answer while the page waited. Once the
// panel has left the page there is nobody to tell, so it stops asking.
async function followCalls(
  review: Review,
  provider: EthereumProvider,
  calls_id: string,
  push: Push,
  leaving: AbortSignal,
): Promise<void> {
  const landed = await landedCalls(review.signer, provider, calls_id, leaving)
  if (leaving.aborted) return
  const [transaction_hash, ...more] = landed?.hashes ?? []
  if (transaction_hash && more.length === 0) push("calls_landed", {calls_id, transaction_hash})
  else if (landed?.status === "failure" && !transaction_hash) push("calls_failed", {calls_id})
  else push("calls_unconfirmed", {calls_id})
}

// Whether Privy's active wallet, as the review's signer, can send its steps together.
async function atomically(review: Review): Promise<boolean> {
  const active = activeEthereumWallet()
  if (active?.address.toLowerCase() !== review.signer.toLowerCase()) return false
  return sendsAtomically(review.chain, review.signer, active.provider)
}

/**
 * The review's inputs as they are on screen now: text as typed, a box as
 * "true" or "false", and a group of choices as the one chosen.
 */
export function formInputs(root: HTMLElement): Record<string, string> {
  const inputs: Record<string, string> = {}
  root.querySelectorAll<HTMLInputElement | HTMLSelectElement>("[data-onchain-input]").forEach(input => {
    const name = input.dataset.onchainInput
    if (!name || card(input) !== root) return
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

// The component's `data-onchain-lost` line, shown when a press could not reach
// the server. The next render from the server hides it again.
function lost(root: HTMLElement, shown: boolean): void {
  const line = root.querySelector<HTMLElement>("[data-onchain-lost]")
  if (line) line.hidden = !shown
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

// The wallet card a button or input belongs to: the nearest one around it. A
// card can sit inside another (Robinhood's refund and claim cards sit in its bid
// card), and a press or a field belongs only to its own.
function card(element: Element): Element | null {
  return element.closest('[phx-hook="OnchainSteps"]')
}
