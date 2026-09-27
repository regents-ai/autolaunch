/**
 * A note that pops up to say something happened, such as a swap going
 * through. It is the answer to what the reader
 * did, so it moves however they asked, unless they asked for less motion.
 */
import {createScope, spring, type AnimationParams, type Scope} from "animejs"
import {play, still} from "../hooks/motion/shared"

const TOASTS: Record<string, AnimationParams> = {
  pop: {scale: {from: 0.6}, opacity: {from: 0}, ease: spring({bounce: 0.45, duration: 360})},
}

function popIn(el: HTMLElement): void {
  if (!still(el)) play(el, TOASTS[el.dataset.variant!])
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
