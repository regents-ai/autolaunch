/**
 * One home product card's moving cell panel (`home_cells.ts`) on the canvas
 * island. The card names its pattern in `data-cells`; the panel's colours come
 * from the stylesheet's `--home-cells-*` colours, the same in both themes, so
 * they are read once. The pointer steers the pattern while a mouse is over the
 * card. With less motion asked for, the panel shows one still moment and does
 * not follow the pointer, and goes back to moving when that changes.
 */
import {createCanvasIsland, type CanvasIslandController} from "../canvas_island"
import type {CellColors, CellPattern, CellRenderer, Rgb} from "../home_cells"

const rgb = (color: string): Rgb => {
  const probe = document.createElement("span")
  probe.style.color = color
  document.body.append(probe)
  const [red = 0, green = 0, blue = 0] = (getComputedStyle(probe).color.match(/[\d.]+/g) ?? []).map(Number)
  probe.remove()
  return [red / 255, green / 255, blue / 255]
}

const colorsOf = (card: HTMLElement): CellColors => {
  const style = getComputedStyle(card)
  const read = (name: string) => rgb(style.getPropertyValue(name).trim())
  return {
    ground: read("--home-cells-ground"),
    lit: read("--home-cells-lit"),
    accent: read("--home-cells-accent"),
    cool: read("--home-cells-cool"),
  }
}

type CellsHook = {el: HTMLElement; controller?: CanvasIslandController}

export const HomeCells = {
  mounted(this: CellsHook) {
    const card = this.el
    const pattern = (card.dataset.cells ?? "payoff") as CellPattern
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
      interact: ({canvas, renderer, nudge, onReady}) => {
        const events = new AbortController()
        const options = {passive: true, signal: events.signal}
        const paint = () => renderer()?.colors(colorsOf(card))
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
        onReady(paint)
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
