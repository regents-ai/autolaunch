/**
 * A launch's price line, drawn with WebGPU from the points the page carries:
 * a soft fill in the image's colour under a round-capped line, and a dot on
 * the latest price. Loaded on demand by the PriceChart hook, so the
 * application entry never carries WebGPU. Drawn once, and again when the
 * points change, the chart changes size or the site switches theme.
 *
 * Every segment is one instanced quad spawned from its index, with no vertex
 * buffers: the fill quad runs from the segment down to the chart's foot, and
 * the line quad hugs the segment while its fragment keeps the pixels within
 * half the line's width of it, which rounds every end and join.
 */

import {draw, frame, init, storage, surface} from "vgpu"

// The server thins a long history to this many points.
const maxPoints = 400

const shader = /* wgsl */ `
struct Params { color: vec4f, size: vec2f, inset: f32, width: f32, count: u32, dpr: f32 }
@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> points: array<vec2f>;

// A point (0–1 across, 0–1 up) in framebuffer pixels, y down.
fn pixel(point: vec2f) -> vec2f {
  let area = params.size - vec2f(2.0 * params.inset);
  return vec2f(params.inset) + vec2f(point.x, 1.0 - point.y) * area;
}

fn clip(at: vec2f) -> vec4f {
  return vec4f(at.x / params.size.x * 2.0 - 1.0, 1.0 - at.y / params.size.y * 2.0, 0.0, 1.0);
}

@vertex fn vs_fill(@builtin(vertex_index) v: u32, @builtin(instance_index) i: u32) -> @builtin(position) vec4f {
  var later = array<bool, 6>(false, true, false, true, true, false);
  var top = array<bool, 6>(true, true, false, true, false, false);
  let corner = select(pixel(points[i]), pixel(points[i + 1u]), later[v]);
  return clip(vec2f(corner.x, select(params.size.y, corner.y, top[v])));
}

@fragment fn fs_fill(@builtin(position) at: vec4f) -> @location(0) vec4f {
  let alpha = 0.22 * pow(1.0 - at.y / params.size.y, 1.5);
  return vec4f(params.color.rgb * alpha, alpha);
}

struct Stroke {
  @builtin(position) position: vec4f,
  @location(0) @interpolate(flat) start: vec2f,
  @location(1) @interpolate(flat) end: vec2f,
  @location(2) @interpolate(flat) radius: f32,
}

// Instances 0 to count - 2 are the segments; the last is the dot.
@vertex fn vs_line(@builtin(vertex_index) v: u32, @builtin(instance_index) i: u32) -> Stroke {
  let last = params.count - 1u;
  let marker = i == last;
  let start = pixel(points[i]);
  let end = select(pixel(points[min(i + 1u, last)]), start, marker);
  let radius = params.width * select(0.5, 1.8, marker);
  let reach = radius + params.dpr;
  let span = end - start;
  let along = select(vec2f(1.0, 0.0), normalize(span), length(span) > 0.001);
  let across = vec2f(-along.y, along.x);
  var ahead = array<f32, 6>(-1.0, 1.0, -1.0, 1.0, 1.0, -1.0);
  var side = array<f32, 6>(-1.0, -1.0, 1.0, -1.0, 1.0, 1.0);
  let base = select(start, end, ahead[v] > 0.0);

  var out: Stroke;
  out.position = clip(base + (along * ahead[v] + across * side[v]) * reach);
  out.start = start;
  out.end = end;
  out.radius = radius;
  return out;
}

@fragment fn fs_line(stroke: Stroke) -> @location(0) vec4f {
  let span = stroke.end - stroke.start;
  let t = clamp(dot(stroke.position.xy - stroke.start, span) / max(dot(span, span), 0.0001), 0.0, 1.0);
  let away = distance(stroke.position.xy, stroke.start + span * t);
  let alpha = clamp((stroke.radius - away) / params.dpr + 0.5, 0.0, 1.0);
  return vec4f(params.color.rgb * alpha, alpha);
}
`

export interface Painter {
  update(): void
  dispose(): void
}

// Any CSS colour as 0–1 channels, read back through a 2D canvas.
type Channels = [number, number, number, number]

function channels(css: string): Channels {
  const context = document.createElement("canvas").getContext("2d")!
  context.fillStyle = css
  const hex = context.fillStyle.slice(1)
  return [0, 2, 4].map(at => Number.parseInt(hex.slice(at, at + 2), 16) / 255).concat(1) as Channels
}

// The page's [block, price] pairs, spread 0–1 across by block and 0–1 up by
// price with room above and below; a flat price sits in the middle.
function normalized(root: HTMLElement): Float32Array<ArrayBuffer> {
  const pairs = JSON.parse(root.dataset.points!) as [number, number][]
  const first = pairs[0][0]
  const blocks = pairs[pairs.length - 1][0] - first || 1
  const prices = pairs.map(([, price]) => price)
  const low = Math.min(...prices)
  const range = Math.max(...prices) - low

  return new Float32Array(
    pairs.flatMap(([block, price]) => [
      (block - first) / blocks,
      range ? 0.12 + ((price - low) / range) * 0.76 : 0.5,
    ]),
  )
}

export async function paint(root: HTMLElement): Promise<Painter> {
  const canvas = root.querySelector<HTMLCanvasElement>("canvas")!
  const gpu = await init()
  const canvasSurface = surface(gpu, canvas, {
    dpr: [1, 2],
    alphaMode: "premultiplied",
    label: "price-chart",
  })
  const points = storage(gpu, maxPoints * 8, "read")
  const fill = draw(gpu, {
    shader,
    vertices: 6,
    blend: "premultiplied",
    entry: {vertex: "vs_fill", fragment: "fs_fill"},
  })
  const line = draw(gpu, {
    shader,
    vertices: 6,
    blend: "premultiplied",
    entry: {vertex: "vs_line", fragment: "fs_line"},
  })

  let count = 0
  const load = () => {
    const data = normalized(root)
    count = data.length / 2
    points.write(data)
  }

  // A frame cannot open inside a resize report, so each draw waits for the
  // next animation frame, and several requests before it share one draw.
  let pending = 0
  const render = () => {
    pending = 0
    const [width] = canvasSurface.size
    const dpr = width / canvas.clientWidth
    const params = {
      color: channels(getComputedStyle(root).getPropertyValue("--price-line").trim()),
      size: canvasSurface.size,
      inset: 6 * dpr,
      width: 2 * dpr,
      count,
      dpr,
    }
    fill.set({params, points})
    line.set({params, points})
    frame(gpu, f =>
      f.pass({target: canvasSurface, clear: [0, 0, 0, 0]}, pass => {
        pass.draw(fill, {instances: count - 1})
        pass.draw(line, {instances: count})
      }),
    )
  }
  const schedule = () => {
    if (!pending) pending = requestAnimationFrame(render)
  }

  load()
  // onResize also reports the current size at once, which asks for the first draw.
  const stopResize = canvasSurface.onResize(schedule)
  const themeObserver = new MutationObserver(schedule)
  themeObserver.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  })

  return {
    update() {
      load()
      schedule()
    },
    dispose() {
      cancelAnimationFrame(pending)
      themeObserver.disconnect()
      stopResize()
      canvasSurface.dispose()
      gpu.dispose()
    },
  }
}
