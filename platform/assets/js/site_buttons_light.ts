/** A soft light on each site's own ground, behind the button it frames.
 * It eases towards the pointer and the button's state, then stops: no clock, no idle loop.
 * Built the way the lab's other islands (code_cube/renderer.ts) are.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {effect, frame, init, surface} from "vgpu"
import type {IslandRenderer} from "./canvas_island"

export type Rgb = readonly [number, number, number]

/** Where the light should rest: x and y across the frame from its top left, and how bright it is. */
export type LightAim = {x: number; y: number; glow: number}

export type LightRenderer = IslandRenderer & {
  colors(ground: Rgb, light: Rgb): void
  aim(target: LightAim, jump: boolean): void
}

// vgpu's effect uv starts at the top left and grows down, the same way the page measures.
const lightWgsl = /* wgsl */ `
struct Params { ground: vec4f, light: vec4f, spot: vec4f, }
@group(0) @binding(0) var<uniform> params: Params;
@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let aspect = params.spot.w;
  let offset = (uv - params.spot.xy) * vec2f(aspect, 1.0);
  let pool = 1.0 - smoothstep(0.0, 1.15, length(offset));
  let edge = smoothstep(0.55, 1.0, max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0);
  let amount = pool * pool * params.spot.z * 0.7 + edge * params.spot.z * 0.06;
  return vec4f(mix(params.ground.rgb, params.light.rgb, clamp(amount, 0.0, 1.0)), 1.0);
}`

// Each frame closes this share of the distance left, so a move settles well inside
// the island's frame budget and the last frame snaps the rest.
const EASE = 0.22

const same = (a: Rgb, b: Rgb) => a.every((channel, i) => Math.abs(channel - b[i]) < 1 / 512)

export async function createLightRenderer(
  canvas: HTMLCanvasElement,
  size: readonly [number, number],
  lost: () => void,
): Promise<LightRenderer> {
  const gpu = await init()
  let disposed = false
  // Disposing the device resolves the same promise, so only a light still on screen reports a loss.
  void gpu.lost.then(() => { if (!disposed) lost() })
  try {
    // The island measures the canvas and caps its pixels, so the surface takes that size as given.
    const output = surface(gpu, canvas, {autoResize: false, alphaMode: "opaque", label: "site-button-light"})
    output.resize([size[0], size[1]])
    let aspect = size[0] / Math.max(1, size[1])
    let ground: Rgb = [0, 0, 0]
    let light: Rgb = [1, 1, 1]
    const now: LightAim = {x: .5, y: .5, glow: 0}
    let target: LightAim = {...now}
    const shader = effect(gpu, prepareShader(lightWgsl, "site_button_light.wgsl"), {
      label: "site-button-light.pass",
      set: {params: {ground: [...ground, 1], light: [...light, 1], spot: [now.x, now.y, now.glow, aspect]}},
    })
    await shader.compile({colors: [output.format]})

    return {
      colors(nextGround, nextLight) {
        if (same(ground, nextGround) && same(light, nextLight)) return
        ground = nextGround
        light = nextLight
        shader.set({params: {ground: [...ground, 1], light: [...light, 1]}})
      },
      aim(next, jump) {
        target = next
        if (jump) Object.assign(now, next)
      },
      resize(width, height) {
        aspect = width / Math.max(1, height)
        output.resize([width, height])
      },
      step(snap) {
        const keys = ["x", "y", "glow"] as const
        const moved = keys.some(key => Math.abs(target[key] - now[key]) > .002)
        for (const key of keys) now[key] = snap || !moved ? target[key] : now[key] + (target[key] - now[key]) * EASE
        return moved
      },
      present() {
        shader.set({params: {spot: [now.x, now.y, now.glow, aspect]}})
        frame(gpu, current => current.pass(output, shader))
      },
      async settled() { await gpu.gpu.queue.onSubmittedWorkDone(); await gpu.settled() },
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
