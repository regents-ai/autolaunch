/**
 * The home product cards' moving pictures: a panel of small coloured glyphs,
 * one pattern for each product, each in its own three-colour gradient
 * (`home_cells/panels.ts`). The pointer steers each one while it is over the
 * card. Time stops for a visitor who asked for less motion, and the island
 * stops drawing whenever the card is off screen or the tab is hidden.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {effect, frame, init, surface} from "vgpu"
import type {IslandRenderer} from "./canvas_island"
import {ground, panels, rgba, shapeFor, type CellPattern} from "./home_cells/panels"

export type {CellPattern}

export type CellRenderer = IslandRenderer & {
  point(at: readonly [number, number] | null): void
  still(still: boolean): void
}

const EASE = 0.14

export async function createCellRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  lost: () => void,
  pattern: CellPattern,
  stillAtStart: boolean,
): Promise<CellRenderer> {
  const gpu = await init()
  let disposed = false
  void gpu.lost.then(() => { if (!disposed) lost() })
  try {
    const output = surface(gpu, canvas, {autoResize: false, alphaMode: "opaque", label: `home-cells-${pattern}`})
    output.resize([size[0], size[1]])
    const panel = panels[pattern]
    // Device pixels for each pixel of the shape the panel is laid out for, so it is the same picture at any size.
    const scale = (bufferWidth: number, bufferHeight: number) => bufferWidth / shapeFor(bufferWidth, bufferHeight)[0]
    let width = size[0]
    let height = size[1]
    let ratio = scale(width, height)
    let still = stillAtStart
    // The moving picture carries on from the still frame's moment, from its first moving step.
    let started: number | null = null
    let shown: number = panel.stillAt
    const now = {x: .5, y: .5, z: 0}
    const target = {x: .5, y: .5, z: 0}
    const shader = effect(gpu, prepareShader(panel.shader, `home_cells_${pattern}.wgsl`), {
      label: `home-cells-${pattern}.pass`,
      set: {
        params: {
          ground: rgba(ground),
          a: rgba(panel.deep),
          b: rgba(panel.main),
          c: rgba(panel.bright),
          pointer: [now.x, now.y, now.z, 0],
          size: [width, height, ratio, shown],
        },
      },
    })
    await shader.compile(output)

    return {
      point(at) {
        // A still panel does not follow the pointer either.
        if (still) return
        if (at) Object.assign(target, {x: at[0], y: at[1], z: 1})
        else target.z = 0
        if (at && now.z < .01) Object.assign(now, {x: at[0], y: at[1]})
      },
      still(next) {
        if (next === still) return
        still = next
        // Going still lets go of the pointer at once.
        if (still) { target.z = 0; now.z = 0 }
        // Moving again carries on from the moment the still picture showed.
        if (!still) started = performance.now() - shown * 1000
      },
      resize(nextWidth, nextHeight) {
        width = nextWidth
        height = nextHeight
        ratio = scale(nextWidth, nextHeight)
        output.resize([width, height])
      },
      step(snap) {
        const keys = ["x", "y", "z"] as const
        const easing = keys.some(key => Math.abs(target[key] - now[key]) > .002)
        for (const key of keys) now[key] = snap || !easing ? target[key] : now[key] + (target[key] - now[key]) * EASE
        if (still) {
          shown = panel.stillAt
          return easing
        }
        started ??= performance.now() - shown * 1000
        shown = (performance.now() - started) / 1000
        return true
      },
      present() {
        shader.set({params: {pointer: [now.x, now.y, now.z, 0], size: [width, height, ratio, shown]}})
        frame(gpu, current => current.pass(output, shader))
      },
      settled: () => gpu.settled(),
      dispose() {
        if (disposed) return
        disposed = true
        output.dispose()
        gpu.dispose()
      },
    }
  } catch (error) {
    disposed = true
    gpu.dispose()
    throw error
  }
}
