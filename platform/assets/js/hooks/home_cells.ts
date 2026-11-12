/**
 * One home product card's moving panel (`home_cells.ts`) on the canvas island.
 * The card names its pattern in `data-cells`, and the pattern brings its own
 * colours. The pointer steers the pattern while a mouse is over the card. With
 * less motion asked for, the panel shows one still moment and does not follow
 * the pointer, and goes back to moving when that changes.
 */
import {createCanvasIsland, type CanvasIslandController} from "../canvas_island"
import type {CellPattern, CellRenderer} from "../home_cells"

type CellsHook = {el: HTMLElement; controller?: CanvasIslandController}

export const HomeCells = {
  mounted(this: CellsHook) {
    const card = this.el
    const pattern = card.dataset.cells as CellPattern
    const reduced = matchMedia("(prefers-reduced-motion: reduce)")

    this.controller = createCanvasIsland<CellRenderer>(card, {}, {
      canvasSelector: "[data-cells-canvas]",
      readyFlag: "cellsReady",
      motionSensitive: false,
      continuous: true,
      browserLoad: async (canvas, size, lost) => {
        const {createCellRenderer} = await import("../home_cells")
        return createCellRenderer(canvas, size, lost, pattern, reduced.matches)
      },
      interact: ({canvas, renderer, nudge}) => {
        const events = new AbortController()
        const options = {passive: true, signal: events.signal}
        const motion = () => {
          renderer()?.still(reduced.matches)
          nudge()
        }
        card.addEventListener("pointermove", (event: PointerEvent) => {
          if (event.pointerType !== "mouse") return
          const {left, top, width, height} = canvas().getBoundingClientRect()
          renderer()?.point([(event.clientX - left) / width, (event.clientY - top) / height])
          nudge()
        }, options)
        card.addEventListener("pointerleave", () => {
          renderer()?.point(null)
          nudge()
        }, options)
        reduced.addEventListener("change", motion)
        return () => {
          events.abort()
          reduced.removeEventListener("change", motion)
        }
      },
    })
    this.controller.mount()
  },
  disconnected(this: CellsHook) {
    this.controller?.pause()
  },
  reconnected(this: CellsHook) {
    this.controller?.resume()
  },
  destroyed(this: CellsHook) {
    this.controller?.destroy()
    this.controller = undefined
  },
}
