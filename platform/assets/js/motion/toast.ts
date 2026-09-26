/**
 * A note that pops up to say something happened, such as a swap going
 * through or an address being copied. It is the answer to what the reader
 * did, so it moves however they asked, unless they asked for less motion.
 */
import {animate, createScope, spring, utils, type AnimationParams, type JSAnimation, type Scope} from "animejs"
import {BASE, still} from "./shared"

type Version = {enter: AnimationParams; leave: AnimationParams}

const TOASTS: Record<string, Version> = {
  pop: {
    enter: {scale: {from: 0.6}, opacity: {from: 0}, ease: spring({bounce: 0.45, duration: 360})},
    leave: {scale: 0.8, opacity: 0, duration: BASE, ease: "in(3)"},
  },
}

const tidy = (animation: JSAnimation) => { utils.cleanInlineStyles(animation) }

export function popIn(el: HTMLElement): void {
  if (!still()) animate(el, {...TOASTS[el.dataset.variant!].enter, onComplete: tidy})
}

// `gone` puts the page back as it is without the note; it runs once the note
// has left, or at once with less motion.
export function popOut(el: HTMLElement, gone: () => void): void {
  if (still()) {
    gone()
    return
  }
  animate(el, {
    ...TOASTS[el.dataset.variant!].leave,
    onComplete: (animation: JSAnimation) => {
      gone()
      utils.cleanInlineStyles(animation)
    },
  })
}

type ToastHook = {el: HTMLElement; scope?: Scope}

// A note the server adds to a live page pops in as it arrives.
export const Toast = {
  mounted(this: ToastHook) {
    this.scope = createScope({root: this.el}).add(() => popIn(this.el))
  },
  destroyed(this: ToastHook) {
    this.scope?.revert()
  },
}
