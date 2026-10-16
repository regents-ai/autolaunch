/**
 * The token page's trade widget, easing from one view's height to the next
 * when another view is chosen (`AutolaunchWeb.Components.TokenTrade`). The
 * server shows the chosen view; this island only measures the height before
 * and after the change and moves between them. Reduced motion, and a choice
 * made from the keyboard, take the new height at once.
 */
import {createScope, type Scope} from "animejs"
import {BASE, EASE_IN_OUT, lastInputByPointer, play, still} from "./motion/shared"

type ViewsHook = {el: HTMLElement; scope?: Scope; active?: string; height?: number}

export const TradeViews = {
  mounted(this: ViewsHook) {
    const scope = createScope({root: this.el})
    this.active = this.el.dataset.active
    this.scope = scope.add(() => {
      scope.add("ease", (from: number, to: number) => {
        this.el.dataset.resizing = ""
        play(this.el, {height: [from, to], duration: BASE, ease: EASE_IN_OUT}).then(() => {
          delete this.el.dataset.resizing
        })
      })
    })
  },

  beforeUpdate(this: ViewsHook) {
    this.height = this.el.offsetHeight
  },

  updated(this: ViewsHook) {
    const from = this.height
    const to = this.el.offsetHeight
    const changed = this.active !== this.el.dataset.active
    this.active = this.el.dataset.active
    if (!changed || from === undefined || from === to || still(this.el) || !lastInputByPointer()) return
    this.scope?.methods.ease(from, to)
  },

  destroyed(this: ViewsHook) {
    this.scope?.revert()
  },
}
