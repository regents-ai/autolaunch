/**
 * Panels that open over the page: a menu pops out under its button and a
 * dialog rises in the middle of the screen. Each names its kind in
 * `data-panel` and its version in `data-variant`, both from
 * `AutolaunchWeb.Motion`. A menu closes at once; a dialog closed with a mouse
 * or finger sinks away first.
 */
import {animate, spring, utils, type AnimationParams, type JSAnimation} from "animejs"
import {BASE, SLOW, moved} from "./shared"

type Version = {away: AnimationParams; open: AnimationParams}

const PANELS: Record<string, Record<string, Version>> = {
  menu: {
    pop: {away: {y: -6, scale: 0.9, opacity: 0}, open: {duration: SLOW, ease: "outBack(2.2)"}},
  },
  dialog: {
    pop: {away: {y: 12, scale: 0.94, opacity: 0}, open: {ease: spring({bounce: 0.3, duration: 380})}},
  },
}

const CLOSE: AnimationParams = {duration: BASE, ease: "in(3)"}

// Where a panel rests when it is open: no offset, full size. Opening names
// both ends, so the page's own styling is all that is left once it ends.
const REST: Record<string, number> = {x: 0, y: 0, scale: 1, opacity: 1}
const arrive = (away: AnimationParams) =>
  Object.fromEntries(Object.entries(away).map(([key, from]) => [key, {from, to: REST[key]}]))

const version = (el: HTMLElement) => PANELS[el.dataset.panel!][el.dataset.variant!]

const moving = new WeakMap<Element, JSAnimation>()

// A panel moved again mid-move is first put back at rest.
function move(el: HTMLElement, params: AnimationParams): void {
  halt(el)
  moving.set(el, animate(el, params))
}

function halt(el: HTMLElement): void {
  const animation = moving.get(el)
  if (animation === undefined) return
  animation.pause()
  utils.cleanInlineStyles(animation)
  moving.delete(el)
}

// The panel has just opened. The backdrop behind a dialog fades in while
// `data-opening` is set.
export function openPanel(el: HTMLElement): void {
  const {away, open} = version(el)
  el.dataset.opening = ""
  move(el, {
    ...arrive(away),
    ...open,
    onComplete: (animation: JSAnimation) => {
      utils.cleanInlineStyles(animation)
      delete el.dataset.opening
    },
  })
}

// Closes the dialog, after its closing motion when the reader closed it with
// a mouse or finger. Its backdrop fades out while `data-closing` is set.
export function closeDialog(dialog: HTMLDialogElement): void {
  if (!dialog.open || "closing" in dialog.dataset) return
  delete dialog.dataset.opening
  if (!moved()) {
    halt(dialog)
    dialog.close()
    return
  }
  dialog.dataset.closing = ""
  move(dialog, {
    ...version(dialog).away,
    ...CLOSE,
    onComplete: (animation: JSAnimation) => {
      utils.cleanInlineStyles(animation)
      delete dialog.dataset.closing
      dialog.close()
    },
  })
}
