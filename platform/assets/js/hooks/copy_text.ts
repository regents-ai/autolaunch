import type {Hook} from "../hook_composition"
import {deny} from "../motion/press"

type Outcome = "copied" | "selected" | "failed"

const WORDS: Record<Outcome, string> = {copied: "Copied", selected: "Selected", failed: "Couldn't copy"}
const SHOWN_MS = 1600

type CopyTextHook = Hook & {
  el: HTMLElement
  outcome?: Outcome
  timer?: number
  onClick?: () => void
}

/**
 * The copy button from `Regent.Primitives.copy_button`. A press copies its
 * `data-copy-text`, or the text of the element `data-copy-target` names, then
 * for a moment the button says "Copied", or "Couldn't copy" with a shake when
 * the browser refuses, and its polite status says the same for screen readers.
 * When the browser refuses and there is a target, the target's text is selected
 * for the person to copy themselves and the button says "Selected". The page
 * may redraw the button meanwhile, or reconnect, so the answer is put back
 * after every redraw until its moment is over.
 */
export const CopyText: Hook = {
  mounted(this: CopyTextHook) {
    this.onClick = () => void copy(this)
    this.el.addEventListener("click", this.onClick)
  },

  updated(this: CopyTextHook) {
    show(this)
  },

  destroyed(this: CopyTextHook) {
    window.clearTimeout(this.timer)
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
  },
}

async function copy(hook: CopyTextHook) {
  const target = hook.el.dataset.copyTarget ? document.getElementById(hook.el.dataset.copyTarget) : null
  let outcome: Outcome = "copied"
  try {
    await navigator.clipboard.writeText(target ? textOf(target) : (hook.el.dataset.copyText ?? ""))
  } catch {
    outcome = target ? select(target) : "failed"
  }
  if (!hook.el.isConnected) return

  answer(hook, outcome)
  if (outcome === "failed") deny(hook.el)
  window.clearTimeout(hook.timer)
  hook.timer = window.setTimeout(() => answer(hook, undefined), SHOWN_MS)
}

function textOf(target: HTMLElement): string {
  return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement
    ? target.value
    : (target.textContent ?? "")
}

// A field selects its own text; anything else, like a prompt shown on the page,
// is selected as a range.
function select(target: HTMLElement): Outcome {
  if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
    target.focus()
    target.select()
    return "selected"
  }

  const selection = document.getSelection()
  if (!selection) return "failed"
  const range = document.createRange()
  range.selectNodeContents(target)
  selection.removeAllRanges()
  selection.addRange(range)
  return "selected"
}

function answer(hook: CopyTextHook, outcome: Outcome | undefined) {
  hook.outcome = outcome
  show(hook)
  const status = document.getElementById(hook.el.dataset.copyStatus ?? "")
  if (status) status.textContent = outcome ? WORDS[outcome] : ""
}

function show(hook: CopyTextHook) {
  if (hook.outcome) hook.el.dataset.copyState = hook.outcome
  else delete hook.el.dataset.copyState
}
