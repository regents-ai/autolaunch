/**
 * What all of Autolaunch's motion shares: Patchbay's timings and curves, and
 * the questions asked before anything moves.
 */
import {cubicBezier} from "animejs"

export const BASE = 200
export const SLOW = 280

export const EASE_OUT = cubicBezier(0.23, 1, 0.32, 1)

// The reader asked for less motion in their system settings.
export function still(): boolean {
  return matchMedia("(prefers-reduced-motion: reduce)").matches
}

// A click from Enter or Space reports no pointer presses. Keyboard-driven UI
// answers at once rather than animating.
export function byPointer(event: MouseEvent): boolean {
  return event.detail > 0
}

// Panels open after a click, a hover, a key or a server reply, so they follow
// the reader's last input: a mouse or finger gets motion, a keyboard does not.
let pointerLast = false

export function trackInput(doc: Document): void {
  const pointer = () => { pointerLast = true }
  doc.addEventListener("pointerdown", pointer, {capture: true, passive: true})
  doc.addEventListener("pointermove", pointer, {capture: true, passive: true})
  doc.addEventListener("keydown", () => { pointerLast = false }, {capture: true, passive: true})
}

export function moved(): boolean {
  return pointerLast && !still()
}
