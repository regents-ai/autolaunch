import type {Hook} from "../hook_composition"
import type {Painter} from "../optics/image_gradient"

type ImageGradientHook = Hook & {el: HTMLElement; painter?: Promise<Painter | undefined>}

// The coin overview's image-colour background. WebGPU loads only on a page that
// shows one; a browser without it keeps the plain card.
export const ImageGradient = {
  mounted(this: ImageGradientHook) {
    this.painter = import("../optics/image_gradient")
      .then(({paint}) => paint(this.el))
      .catch(() => undefined)
  },
  destroyed(this: ImageGradientHook) {
    void this.painter?.then(painter => painter?.dispose())
  },
}
