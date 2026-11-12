/**
 * The home product cards' moving pictures: a panel of small lit cells, like an
 * instrument's display, one pattern for each product. Covered calls draws a
 * call's payoff, flat then rising past a strike that drifts; Memestock draws two
 * colours meeting along a seam, the stock's and the memecoin's; Revstake draws
 * revenue as bars that rise and fall, each topped in the accent. The pointer
 * steers each one while it is over the card. Time stops for a visitor who asked
 * for less motion, and the island stops drawing whenever the card is off screen
 * or the tab is hidden.
 */
import {prepareShader} from "@vgpu/wgsl/prepare"
import {effect, frame, init, surface} from "vgpu"
import type {IslandRenderer} from "./canvas_island"

export type Rgb = readonly [number, number, number]
export type CellPattern = "payoff" | "pair" | "split"
export type CellColors = {ground: Rgb; lit: Rgb; accent: Rgb; cool: Rgb}

export type CellRenderer = IslandRenderer & {
  colors(colors: CellColors): void
  point(at: readonly [number, number] | null): void
  still(still: boolean): void
}

const common = /* wgsl */ `
struct Params {
  ground: vec4f,
  lit: vec4f,
  accent: vec4f,
  cool: vec4f,
  pointer: vec4f,
  size: vec4f,
}
@group(0) @binding(0) var<uniform> params: Params;

fn sq(v: f32) -> f32 { return v * v; }
fn hash(p: vec2f) -> f32 { return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453); }
fn noise(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2f(1.0, 0.0)), u.x), mix(hash(i + vec2f(0.0, 1.0)), hash(i + vec2f(1.0, 1.0)), u.x), u.y);
}
// A rounded box's signed distance, in pixels.
fn box(p: vec2f, half: vec2f, r: f32) -> f32 {
  let q = abs(p) - half + vec2f(r);
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}
struct Cell { id: vec2f, count: vec2f, centre: vec2f, inside: f32, halo: f32 }
// The grid of cells inside an inset frame: which cell this pixel is in, how many
// there are, the cell's centre as 0..1 across the frame (y up), and how much of
// the pixel the cell's shape covers.
fn cell(uv: vec2f, pitch: vec2f, half: vec2f, r: f32) -> Cell {
  let s = params.size.z;
  let inset = 12.0 * s;
  let area = params.size.xy - vec2f(inset * 2.0);
  let count = max(floor(area / (pitch * s)), vec2f(1.0));
  let room = area / count;
  let px = uv * params.size.xy - vec2f(inset);
  let id = clamp(floor(px / room), vec2f(0.0), count - 1.0);
  let local = px - (id + 0.5) * room;
  let d = box(local, half * s, r * s);
  let inside = (1.0 - smoothstep(-0.75 * s, 0.75 * s, d)) * step(0.0, px.x) * step(0.0, px.y) * step(px.x, area.x) * step(px.y, area.y);
  let centre = vec2f((id.x + 0.5) / count.x, 1.0 - (id.y + 0.5) / count.y);
  // A soft light just outside each cell, so a lit cell glows a little into the gap.
  let halo = exp(-max(d, 0.0) / (2.2 * s)) * (1.0 - inside) * step(0.0, px.x) * step(0.0, px.y) * step(px.x, area.x) * step(px.y, area.y);
  return Cell(id, count, centre, inside, halo);
}
fn time() -> f32 { return params.size.w; }
// The pointer across the frame (y up), and how present it is.
fn pointer() -> vec3f { return vec3f(params.pointer.x, 1.0 - params.pointer.y, params.pointer.z); }
// An unlit cell is a faint shape; a lit one takes its colour and glows into the gap.
fn shade(colour: vec3f, amount: f32, c: Cell) -> vec3f {
  let off = mix(params.ground.rgb, params.lit.rgb, 0.07);
  let face = mix(params.ground.rgb, mix(off, colour, amount), c.inside);
  return face + colour * c.halo * amount * amount * 0.22;
}
`

const shaders: Record<CellPattern, string> = {
  payoff: /* wgsl */ `${common}
@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let c = cell(uv, vec2f(10.0, 15.0), vec2f(2.6, 5.4), 2.6);
  let p = pointer();
  let drift = 0.46 + 0.16 * sin(time() * 0.55) + 0.05 * sin(time() * 1.3 + 1.0);
  let strike = mix(drift, clamp(p.x, 0.15, 0.85), p.z);
  let x = c.centre.x;
  let floorLine = 0.2;
  let payoff = min(floorLine + max(x - strike, 0.0) * 1.7, 0.96);
  let y = c.centre.y;
  let filled = step(y, payoff);
  // The top cell of each column is the brightest; the floor left of the strike is
  // the premium, a deeper tone.
  let top = 1.0 - smoothstep(0.0, 0.14, payoff - y);
  let premium = step(x, strike) * step(y, floorLine);
  var colour = mix(params.accent.rgb * 0.62, params.accent.rgb, top);
  colour = mix(colour, mix(params.accent.rgb, params.lit.rgb, 0.55), top * step(strike, x) * 0.5);
  colour = mix(colour, params.accent.rgb * 0.45, premium * (1.0 - top));
  // A light that runs along the payoff from left to right.
  let run = fract(time() * 0.18);
  let glint = exp(-sq((x - run) * 9.0)) * filled * 0.5;
  // The strike itself: a faint column full height.
  let line = (1.0 - smoothstep(0.0, 0.6 / c.count.x, abs(x - strike))) * (1.0 - filled) * 0.35;
  let amount = filled * (0.82 + glint) + line;
  let lineColour = mix(colour, params.lit.rgb, line * 2.0);
  return vec4f(shade(lineColour, clamp(amount, 0.0, 1.0), c), 1.0);
}`,
  pair: /* wgsl */ `${common}
@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let c = cell(uv, vec2f(8.0, 16.0), vec2f(3.0, 5.0), 1.2);
  let p = pointer();
  let row = c.id.y;
  let y = c.centre.y;
  // Each row's seam sways on its own; near the pointer every seam bends to it.
  var seam = 0.5 + 0.2 * sin(time() * 0.8 + row * 0.42) + 0.08 * sin(time() * 1.7 - row * 0.9);
  let reach = exp(-sq((y - p.y) * 3.2)) * p.z;
  seam = mix(seam, p.x, reach);
  let x = c.centre.x;
  let side = smoothstep(seam - 0.1, seam + 0.1, x);
  let colour = mix(params.cool.rgb, params.accent.rgb, side);
  // The cells at the seam burn brightest, where the two meet.
  let meet = exp(-sq((x - seam) * 10.0));
  let lit = mix(colour, params.lit.rgb, meet * 0.45);
  let amount = 0.55 + 0.45 * meet + 0.15 * abs(x - 0.5);
  return vec4f(shade(lit, clamp(amount, 0.0, 1.0), c), 1.0);
}`,
  split: /* wgsl */ `${common}
@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let c = cell(uv, vec2f(10.0, 13.0), vec2f(3.2, 4.4), 1.0);
  let p = pointer();
  let x = c.centre.x;
  let y = c.centre.y;
  let column = c.id.x;
  let wave = noise(vec2f(column * 0.22, time() * 0.7)) * 0.62 + noise(vec2f(column * 0.9 + 9.0, time() * 1.6)) * 0.38;
  let lift = exp(-sq((x - p.x) * 6.0)) * p.z * 0.35;
  let height = clamp(0.12 + wave * 0.82 + lift, 0.05, 0.97);
  let filled = step(y, height);
  let cellH = 1.0 / c.count.y;
  let tip = step(height - cellH * 1.6, y) * filled;
  let colour = mix(params.lit.rgb, params.accent.rgb, tip);
  let amount = filled * mix(0.8, 1.0, tip);
  return vec4f(shade(colour, amount, c), 1.0);
}`,
}

const EASE = 0.14
const same = (a: Rgb, b: Rgb) => a.every((channel, i) => Math.abs(channel - b[i]) < 1 / 512)

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
    // Device pixels for each CSS pixel of the canvas: the island caps the backing store.
    const scale = (bufferWidth: number) => Math.max(1, bufferWidth / Math.max(1, canvas.getBoundingClientRect().width))
    let width = size[0]
    let height = size[1]
    let ratio = scale(size[0])
    let palette: CellColors = {ground: [.06, .07, .08], lit: [.9, .89, .82], accent: [1, .36, .1], cool: [.68, .79, .8]}
    let still = stillAtStart
    // A still picture shows a moment with every pattern well formed.
    const STILL_AT = 2.4
    let started = performance.now()
    let shown = STILL_AT
    const now = {x: .5, y: .5, z: 0}
    const target = {x: .5, y: .5, z: 0}
    const four = (rgb: Rgb) => [rgb[0], rgb[1], rgb[2], 1]
    const shader = effect(gpu, prepareShader(shaders[pattern], `home_cells_${pattern}.wgsl`), {
      label: `home-cells-${pattern}.pass`,
      set: {
        params: {
          ground: four(palette.ground),
          lit: four(palette.lit),
          accent: four(palette.accent),
          cool: four(palette.cool),
          pointer: [now.x, now.y, now.z, 0],
          size: [width, height, ratio, shown],
        },
      },
    })
    await shader.compile(output)

    return {
      colors(next) {
        if ((["ground", "lit", "accent", "cool"] as const).every(key => same(palette[key], next[key]))) return
        palette = next
        shader.set({params: {ground: four(next.ground), lit: four(next.lit), accent: four(next.accent), cool: four(next.cool)}})
      },
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
        ratio = scale(nextWidth)
        output.resize([width, height])
      },
      step(snap) {
        const keys = ["x", "y", "z"] as const
        const easing = keys.some(key => Math.abs(target[key] - now[key]) > .002)
        for (const key of keys) now[key] = snap || !easing ? target[key] : now[key] + (target[key] - now[key]) * EASE
        if (still) {
          shown = STILL_AT
          return easing
        }
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
