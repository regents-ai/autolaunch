/**
 * Panels that open over the page: the phone menu slides out as a drawer, a
 * dialog rises as a sheet, a header menu pops under its button, a list, such
 * as the pairing window's agents, drops under its dropdown and a trade's
 * review rises over the form it reviews. The page
 * opens and closes them itself; this only moves a panel from where it starts
 * to where it rests, then hands it back to its stylesheet. Closing is
 * immediate, except for a list, which leaves the way it came.
 *
 * Moves in percent name both ends, so they stay a share of the panel's own
 * size instead of being converted to pixels.
 */
import {createScope, spring, stagger} from "animejs"
import {BASE, EASE_OUT, SLOW, lastInputByPointer, play, rest, still} from "./shared"
import type {Hook} from "../../hook_composition"

// The phone menu sits against the left edge, so its drawer comes from there.
export const drawer = (el: Element) =>
  play(el, {x: ["-100%", "0%"], ease: spring({bounce: 0.3, duration: 380})})

export const sheet = (el: Element) =>
  play(el, {y: ["100%", "0%"], ease: spring({bounce: 0.35, duration: 400})})

export const menu = (el: Element) =>
  play(el, {
    y: {from: -6},
    scale: {from: 0.9},
    opacity: {from: 0},
    duration: SLOW,
    ease: "outBack(2.2)",
  })

// A list fades in and rises a little, its items one after another, in about
// 160 ms. Every item can be pressed from the first frame.
export function list(el: HTMLElement) {
  settle(el)
  play(el, {opacity: {from: 0}, y: {from: 4}, duration: 100, ease: EASE_OUT})
  return play(items(el), {opacity: {from: 0}, y: {from: 4}, duration: 110, delay: stagger(5), ease: EASE_OUT})
}

// Closing a list hides it at once in the page, so it stays drawn while it
// leaves, quicker than it came, and a press on it lands on what is under it
// (`data-leaving`, in components/motion.css).
export function unlist(el: HTMLElement) {
  el.dataset.leaving = ""
  return play(el, {opacity: {to: 0}, y: {to: 4}, duration: 100, ease: EASE_OUT}).then(() => {
    delete el.dataset.leaving
  })
}

// A list that opens with no move, from a key or with less motion asked for:
// one still leaving stops there and shows at rest.
export function settle(el: HTMLElement) {
  rest([el, ...items(el)])
  delete el.dataset.leaving
}

// A list's items, without the name a fieldset gives it.
const items = (el: HTMLElement) => [...el.children].filter(child => !(child instanceof HTMLLegendElement))

// A review fades in as it rises a little over its form. Its wallet button
// takes presses from the first frame.
export const review = (el: Element) =>
  play(el, {y: {from: 10}, opacity: {from: 0}, duration: SLOW, ease: EASE_OUT})

export const backdrop = (el: Element) =>
  play(el, {opacity: {from: 0}, duration: BASE, ease: EASE_OUT})

// How each kind of panel, named in `data-panel`, moves when it opens.
const PANELS: Record<string, (el: Element) => unknown> = {drawer, sheet, menu, review}

type PanelsHook = {el: HTMLElement; scope?: ReturnType<typeof createScope>; watch?: MutationObserver}

/**
 * An island whose panels, each marked `data-panel`, are opened by LiveView
 * commands or by the server rather than by a press the page follows, such as
 * a menu a button opens with `JS.show`. A command acts only after the press
 * has reached the document, so this watches each panel's `hidden` go and
 * moves it then, when the reader was last using a mouse or a finger. The
 * island may be a panel itself, as a review is.
 */
export const MotionPanels: Hook = {
  mounted(this: PanelsHook) {
    const scope = createScope({root: this.el})
    this.scope = scope.add("open", (el: HTMLElement) => PANELS[el.dataset.panel ?? ""](el))
    const panels = () =>
      [this.el, ...this.el.querySelectorAll<HTMLElement>("[data-panel]")].filter(el => el.dataset.panel !== undefined)
    const open = new Set(panels().filter(el => !el.hidden))

    // A panel that closes stops any move still playing, so it reopens at rest.
    this.watch = new MutationObserver(() => {
      for (const el of panels()) {
        if (el.hidden && open.delete(el)) rest(el)
        if (el.hidden || open.has(el)) continue
        open.add(el)
        if (lastInputByPointer() && !still(el)) scope.methods.open(el)
      }
    })
    this.watch.observe(this.el, {subtree: true, attributes: true, attributeFilter: ["hidden"]})
  },

  destroyed(this: PanelsHook) {
    this.watch?.disconnect()
    this.scope?.revert()
  },
}
