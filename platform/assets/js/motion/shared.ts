/**
 * What all of Autolaunch's motion shares: Patchbay's timings and curves, and
 * the questions asked before anything moves.
 */
import {animate, cubicBezier, utils, type AnimationParams, type JSAnimation} from "animejs"

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

// Anime.js hands an element back to its stylesheet by restoring the inline
// style it found when the animation began. One begun over another's
// half-way frame would end on that frame, so each run first puts its
// elements back as they were before the last run on them began. Every run
// then starts from rest, and ends there with no inline style left behind.
// Only a run still under way is remembered.
const playing = new WeakMap<Element, JSAnimation>()

export function play(targets: Element | Element[], params: AnimationParams): JSAnimation {
  const els = [targets].flat()
  for (const el of els) playing.get(el)?.revert()
  const animation = animate(els, {
    ...params,
    onComplete: (done) => {
      utils.cleanInlineStyles(done)
      for (const el of els) if (playing.get(el) === done) playing.delete(el)
    },
  })
  for (const el of els) playing.set(el, animation)
  return animation
}

// Stops an element's move where it stands and hands it back to its stylesheet.
export function halt(el: Element): void {
  playing.get(el)?.revert()
  playing.delete(el)
}
