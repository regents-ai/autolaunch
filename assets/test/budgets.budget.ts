import {readFileSync} from "node:fs"
import {gzipSync} from "node:zlib"

import {describe, expect, it} from "vitest"

// Whichever build last wrote them: the unminified development bundle is the
// larger of the two, so a ceiling it clears is one the shipped build clears.
const builtAsset = (name: string) =>
  readFileSync(new URL(`../../priv/static/assets/js/${name}`, import.meta.url))

describe("built asset budgets", () => {
  it("keeps JavaScript at or below 80 KiB gzip", () => {
    expect(gzipSync(builtAsset("app.js")).byteLength).toBeLessThanOrEqual(80 * 1024)
  })

  it("keeps CSS at or below 12 KiB gzip", () => {
    expect(gzipSync(builtAsset("app.css")).byteLength).toBeLessThanOrEqual(12 * 1024)
  })

  it("keeps the Privy bridge chunk at or below 198 KiB gzip", () => {
    expect(gzipSync(builtAsset("privy_bridge.js")).byteLength).toBeLessThanOrEqual(198 * 1024)
  })
})
