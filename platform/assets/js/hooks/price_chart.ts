import type {Hook} from "../hook_composition"
import type {Painter} from "../optics/price_chart"

type PriceChartHook = Hook & {
  el: HTMLElement
  painter?: Promise<Painter | undefined>
}

// A launch's price line. WebGPU loads only on a page that shows one; a browser
// without it keeps the caption, which says how far the price moved, and marks
// the canvas so the empty box folds away. The canvas is left out of page
// updates, so the mark stays.
export const PriceChart = {
  mounted(this: PriceChartHook) {
    this.painter = import("../optics/price_chart")
      .then(({paint}) => paint(this.el))
      .catch(() => {
        this.el.querySelector("canvas")!.dataset.unavailable = "true"
        return undefined
      })
  },
  updated(this: PriceChartHook) {
    void this.painter?.then(painter => painter?.update())
  },
  destroyed(this: PriceChartHook) {
    void this.painter?.then(painter => painter?.dispose())
  },
}
