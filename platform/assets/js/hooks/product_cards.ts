/**
 * The home page's product cards. Each card's line drawing is the ink of the
 * shared holographic foil (ash-template `hooks/holographic_card.ts`, drawn on
 * the island's canvas), lit where the pointer stands while it is over the card.
 */
import type {HolographicCardRenderer} from "../../vendor/regent_ui/holographic_card.mjs"
import {createCanvasIsland, type CanvasIslandController, type LoadRenderer} from "../canvas_island"

/** A computed `rgb(…)` colour as the three 0..1 channels the renderer takes. */
const channels = (color: string): readonly [number, number, number] => {
  const [red = 0, green = 0, blue = 0] = (color.match(/[\d.]+/g) ?? []).map(Number)
  return [red / 255, green / 255, blue / 255]
}

/** The foil as the ink of the card's drawing, on the card's own fill. */
const browserLoadInk =
  (card: HTMLElement): LoadRenderer<HolographicCardRenderer> =>
  async (canvas, size, onDeviceLost) => {
    const {createHolographicCardRenderer, holographicInkMask} = await import(
      "../../vendor/regent_ui/holographic_card.mjs"
    )
    const drawing = canvas.closest(".rg-technical-figure__art")?.querySelector("svg")
    if (!drawing) throw new Error("foil ink needs the line drawing beside its canvas")
    canvas.style.maskImage = holographicInkMask(drawing)
    return createHolographicCardRenderer(canvas, size, onDeviceLost, {
      crown: false,
      ink: channels(getComputedStyle(drawing).color),
      ground: channels(getComputedStyle(card).backgroundColor),
    })
  }

const foilController = (card: HTMLElement): CanvasIslandController =>
  createCanvasIsland<HolographicCardRenderer>(card, {}, {
    canvasSelector: "[data-holo-canvas]",
    readyFlag: "holoReady",
    browserLoad: browserLoadInk(card),
    motionSensitive: true,
    continuous: false,
    interact({root, canvas, renderer, nudge}) {
      const fine = matchMedia("(pointer: fine)").matches
      const events = new AbortController()
      if (fine) {
        root.addEventListener("pointermove", (event: PointerEvent) => {
          if (!event.isPrimary) return
          const {left, top, width, height} = canvas().getBoundingClientRect()
          renderer()?.point([(event.clientX - left) / width, (event.clientY - top) / height])
          nudge()
        }, {passive: true, signal: events.signal})
        root.addEventListener("pointerleave", () => {
          renderer()?.rest()
          nudge()
        }, {passive: true, signal: events.signal})
      }
      return () => events.abort()
    },
  })

type FoilHook = {el: HTMLElement; controller?: CanvasIslandController; release?: () => void}

/**
 * One card's foil. The ink and its ground are the drawing's colours when the
 * renderer is made, so a theme switch makes it again in the new colours.
 */
export const ProductFoil = {
  mounted(this: FoilHook) {
    const start = () => {
      this.controller?.destroy()
      this.controller = foilController(this.el)
      this.controller.mount()
    }
    const theme = new MutationObserver(start)
    theme.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
    const scheme = matchMedia("(prefers-color-scheme: dark)")
    scheme.addEventListener("change", start)
    this.release = () => {
      theme.disconnect()
      scheme.removeEventListener("change", start)
    }
    start()
  },
  disconnected(this: FoilHook) {
    this.controller?.pause()
  },
  reconnected(this: FoilHook) {
    this.controller?.resume()
  },
  destroyed(this: FoilHook) {
    this.release?.()
    this.controller?.destroy()
    this.controller = undefined
  },
}
