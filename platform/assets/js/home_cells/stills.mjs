// Draws the home product cards' still frames into priv/static/images/home/:
// each panel at its still moment, in each of the three shapes it takes
// (<pattern>-square.webp, -broad.webp and -strip.webp). The colours, shapes
// and shaders are the site's own, read from panels.ts beside this file.
//
//   npm run stills:home      (from platform/, after changing panels.ts)
//
// vgpu draws each frame on this machine's GPU; a headless browser only packs
// the pixels as WebP.
import {mkdirSync, writeFileSync} from "node:fs"
import {createRequire} from "node:module"
import {dirname, join} from "node:path"
import {fileURLToPath} from "node:url"
import {prepareShader} from "@vgpu/wgsl/prepare"
import {effect, frame, init, target} from "vgpu/node"
import {ground, panels, rgba, shapes} from "./panels.ts"

const {chromium} = createRequire(import.meta.url)("playwright")
const here = dirname(fileURLToPath(import.meta.url))
const out = join(here, "../../../priv/static/images/home")
// Device pixels for each CSS pixel of the shape: sharp on a dense screen at the sizes the cards take.
const DENSITY = 2.4

mkdirSync(out, {recursive: true})
const gpu = await init()
const browser = await chromium.launch()
const page = await browser.newPage()

for (const [pattern, panel] of Object.entries(panels)) {
  for (const [shape, [across, down]] of Object.entries(shapes)) {
    const width = Math.round(across * DENSITY)
    const height = Math.round(down * DENSITY)
    const frameTarget = target(gpu, {size: [width, height], format: "rgba8unorm"})
    const shader = effect(gpu, prepareShader(panel.shader, `home_cells_${pattern}.wgsl`), {
      set: {
        params: {
          ground: rgba(ground),
          a: rgba(panel.deep),
          b: rgba(panel.main),
          c: rgba(panel.bright),
          pointer: [0.5, 0.5, 0, 0],
          size: [width, height, width / across, panel.stillAt],
        },
      },
    })
    frame(gpu, current => current.pass(frameTarget, shader))
    const read = await frameTarget.color.read({mipLevel: 0, region: "all"})
    const pixels = read.data ?? read
    const webp = await page.evaluate(
      async ([base64, w, h]) => {
        const bytes = Uint8ClampedArray.from(atob(base64), character => character.charCodeAt(0))
        const canvas = new OffscreenCanvas(w, h)
        canvas.getContext("2d").putImageData(new ImageData(bytes, w, h), 0, 0)
        const packed = new Uint8Array(await (await canvas.convertToBlob({type: "image/webp", quality: 0.8})).arrayBuffer())
        return btoa(Array.from(packed, byte => String.fromCharCode(byte)).join(""))
      },
      [Buffer.from(pixels.buffer, pixels.byteOffset, width * height * 4).toString("base64"), width, height],
    )
    const file = `${pattern}-${shape}.webp`
    writeFileSync(join(out, file), Buffer.from(webp, "base64"))
    console.log(file, `${width}x${height}`)
  }
}

await browser.close()
gpu.dispose()
