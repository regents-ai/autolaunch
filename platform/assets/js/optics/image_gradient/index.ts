/**
 * The coin overview's background: the coin image's colour fading into the
 * theme's card colour, after the vgpu "Simple Gradient" example and its soft
 * vignette. Loaded on demand by the ImageGradient hook, so the application
 * entry never carries WebGPU. Drawn once, and again only when the card changes
 * size or the site switches between light and dark.
 */

import {effect, frame, init, surface} from "vgpu"

const shader = /* wgsl */ `
struct Params { image: vec4f, theme: vec4f }
@group(0) @binding(0) var<uniform> params: Params;

@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let vignette = smoothstep(1.2, 0.2, distance(uv, vec2f(0.5)));
  let reach = smoothstep(0.0, 1.0, uv.x * 0.7 + uv.y * 0.5);
  let tint = mix(params.image.rgb, params.theme.rgb, reach);
  return vec4f(mix(params.theme.rgb, tint, 0.6 + 0.4 * vignette), 1.0);
}
`

export interface Painter {
  dispose(): void
}

// Any CSS colour as 0–1 channels, read back through a 2D canvas.
function channels(css: string): [number, number, number, number] {
  const context = document.createElement("canvas").getContext("2d")!
  context.fillStyle = css
  const hex = context.fillStyle.slice(1)
  return [0, 2, 4].map(at => Number.parseInt(hex.slice(at, at + 2), 16) / 255).concat(1) as [
    number,
    number,
    number,
    number,
  ]
}

function colours(root: HTMLElement) {
  const style = getComputedStyle(root)
  return {
    image: channels(style.getPropertyValue("--image-color").trim()),
    theme: channels(style.getPropertyValue("--color-surface").trim()),
  }
}

export async function paint(root: HTMLElement): Promise<Painter> {
  const canvas = root.querySelector<HTMLCanvasElement>("canvas")!
  const gpu = await init()
  const canvasSurface = surface(gpu, canvas, {dpr: [1, 1.5], label: "coin-gradient"})
  const gradient = effect(gpu, shader, {set: {params: colours(root)}})

  // A frame cannot open inside a resize report, so each draw waits for the
  // next animation frame, and several requests before it share one draw.
  let pending = 0
  const draw = () => {
    pending = 0
    frame(gpu, f => f.pass(canvasSurface, gradient))
    root.dataset.gradientReady = "true"
  }
  const schedule = () => {
    if (!pending) pending = requestAnimationFrame(draw)
  }
  const retheme = () => {
    gradient.set({params: colours(root)})
    schedule()
  }

  // onResize also reports the current size at once, which asks for the first draw.
  const stopResize = canvasSurface.onResize(schedule)
  const themeObserver = new MutationObserver(retheme)
  themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})

  return {
    dispose() {
      cancelAnimationFrame(pending)
      themeObserver.disconnect()
      stopResize()
      canvasSurface.dispose()
      gpu.dispose()
    },
  }
}
