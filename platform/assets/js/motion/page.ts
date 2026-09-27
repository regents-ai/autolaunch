/**
 * Autolaunch's standard motion on every page, following Patchbay's: a squish
 * when something is pressed, a shake when a button cannot be used yet, and
 * menus and dialogs popping open. A press from the keyboard, or a reader who
 * asked for less motion, gets none of it.
 *
 * Dialogs opened with `autolaunch:open-dialog` and closed with
 * `autolaunch:close-dialog` open and close here, so their closing motion can
 * play first.
 */
import {byPointer, lastInputByPointer, still, watchInput} from "../hooks/motion/shared"
import {nope, squish} from "../hooks/motion/press"
import {closeDialog, openPanel} from "./panels"

// Buttons, links drawn as buttons or marked `data-squish`, and the button that
// opens a menu.
const PRESSABLE = "button, .rg-button, [role='button'], [data-squish], details:has(> [data-panel]) > summary"

export function installMotion(doc: Document = document): void {
  watchInput(doc)
  doc.addEventListener("click", press)
  doc.addEventListener("beforetoggle", popover, {capture: true})
  doc.addEventListener("autolaunch:open-dialog", (event) => asDialog(event.target)?.showModal())
  doc.addEventListener("autolaunch:close-dialog", (event) => {
    const dialog = asDialog(event.target)
    if (dialog !== null) closeDialog(dialog)
  })

  new MutationObserver(opened).observe(doc.body, {
    subtree: true,
    attributes: true,
    attributeFilter: ["open", "hidden"],
    attributeOldValue: true,
  })
}

const asDialog = (target: EventTarget | null) => (target instanceof HTMLDialogElement ? target : null)

function press(event: MouseEvent): void {
  const el = event.target instanceof Element ? event.target.closest(PRESSABLE) : null
  if (el === null || !byPointer(event) || still(el)) return
  if (el.getAttribute("aria-disabled") === "true") nope(el)
  else squish(el)
}

// A dialog or menu opening sets `open` on it, and a list that opens shows
// itself by dropping `hidden`. The observer answers before the page is next
// drawn, so the panel never shows at rest first.
function opened(records: MutationRecord[]): void {
  if (!lastInputByPointer()) return
  for (const {target, attributeName, oldValue} of records) {
    if (!(target instanceof HTMLElement) || still(target)) continue
    if (attributeName === "open" && oldValue === null && target.hasAttribute("open")) {
      const panel = target.matches("[data-panel]") ? target : target.querySelector<HTMLElement>(":scope > [data-panel]")
      if (panel !== null) openPanel(panel)
    } else if (attributeName === "hidden" && oldValue !== null && !target.hidden && "panel" in target.dataset) {
      openPanel(target)
    }
  }
}

// A popover shows without changing any attribute, so it is caught as it is
// about to open.
function popover(event: Event): void {
  const target = event.target
  if (!(event instanceof ToggleEvent) || !(target instanceof HTMLElement)) return
  if (event.newState === "open" && target.hasAttribute("popover") && "panel" in target.dataset && lastInputByPointer() && !still(target)) {
    openPanel(target)
  }
}
