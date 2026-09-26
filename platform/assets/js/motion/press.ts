/**
 * Small answers to a mouse or finger press. The button still does its job the
 * instant it is pressed; the motion only plays alongside it, so a wallet
 * button reaches the wallet on every press as before.
 */
import {animate, utils, type JSAnimation} from "animejs"
import {still} from "./shared"

// Both end where they began, then hand the element back to its stylesheet.
// One pressed again mid-move starts over from wherever it is.
const tidy = (animation: JSAnimation) => { utils.cleanInlineStyles(animation) }

export const squish = (el: Element) =>
  animate(el, {
    scale: [{to: 0.9, duration: 90, ease: "out(3)"}, {to: 1, duration: 360, ease: "outBack(3)"}],
    onComplete: tidy,
  })

export const nope = (el: Element) =>
  animate(el, {x: [0, -7, 6, -4, 2, 0], duration: 380, ease: "inOut(2)", onComplete: tidy})

// Something was refused. Unlike a press, the shake plays however the refused
// thing was asked for, because it is the answer, not decoration.
export function deny(el: Element): void {
  if (!still()) nope(el)
}
