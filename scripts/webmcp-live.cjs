// Checks the live site the way a browser agent does: opens a page in headless
// Chromium, confirms Chrome's WebMCP trial is on for it, lists the tools the
// page registers and runs one public read through Chrome's own executeTool.
//
//   node scripts/webmcp-live.cjs [https://autolaunch.sh/]
//
// Needs `npm ci` in platform/ and a Chromium the WebMCP trial covers (up to Chrome 162).
// Exits 1 when the token, document.modelContext, a site tool or the read is missing.
const path = require("node:path")
const {chromium} = require(path.join(__dirname, "../platform/node_modules/playwright"))
const manifest = require("../platform/priv/tool_manifest.json")

;(async () => {
  const url = process.argv[2] || "https://autolaunch.sh/"
  const browser = await chromium.launch()
  const page = await browser.newPage()
  const response = await page.goto(url, {waitUntil: "networkidle"})

  // A token is a version byte, a 64-byte signature, a 4-byte length and the JSON it signs.
  const token = Buffer.from(response.headers()["origin-trial"] || "", "base64")
  const trial = token.length > 69 ? JSON.parse(token.subarray(69, 69 + token.readUInt32BE(65))) : null

  const seen = await page.evaluate(async () => {
    if (!("modelContext" in document)) return {modelContext: false, tools: []}
    const tools = await document.modelContext.getTools()
    const counts = tools.find(tool => tool.name === "autolaunch_auction_counts")
    const read = counts ? JSON.parse(await document.modelContext.executeTool(counts, {})) : null
    return {modelContext: true, tools: tools.map(tool => tool.name), read}
  })

  const expected = manifest.tools.filter(tool => tool.scope === "site").map(tool => tool.name)
  const missing = expected.filter(name => !seen.tools.includes(name))
  const checks = {
    "a live WebMCP token for this host": Boolean(trial) && trial.feature === "WebMCP" &&
      trial.origin === `${new URL(url).origin}:443` && trial.expiry * 1000 > Date.now(),
    "Permissions-Policy allows tools": (response.headers()["permissions-policy"] || "").includes("tools=(self)"),
    "document.modelContext is on": seen.modelContext,
    "every site tool is registered": seen.tools.length > 0 && missing.length === 0,
    "autolaunch_auction_counts reads through Chrome": Boolean(seen.read && seen.read.ok),
  }

  console.log(JSON.stringify({url, status: response.status(), chromium: browser.version(), trial,
    tools: seen.tools, missing, read: seen.read, checks}, null, 2))
  await browser.close()
  process.exit(Object.values(checks).every(Boolean) ? 0 : 1)
})()
