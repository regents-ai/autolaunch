// Optional integration proof against the synthetic Autolaunch public-tool fixtures.
// Requires an explicitly supplied loopback server, never production.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { promisify } from "node:util";

const root = resolve(import.meta.dirname, "..");
const origin = new URL(process.argv[2]);
assert.equal(origin.protocol, "http:");
assert.ok(["127.0.0.1", "localhost"].includes(origin.hostname));
assert.equal(origin.username + origin.password + origin.search + origin.hash, "");
assert.equal(origin.pathname, "/");
const active = "a12ee155-c71b-4107-87fd-dab8c7e00001";
const closed = "a12ee155-c71b-4107-87fd-dab8c7e00002";
const treasury = "0x9999999999999999999999999999999999999999";
const outputRoot = resolve(root, "output");
await mkdir(outputRoot, { recursive: true });
const evidenceDir = await mkdtemp(resolve(outputRoot, "public-cli-"));
const cases = [
  { args: ["auctions", "list"], path: "/api/v1/auctions" },
  ...["all", "biddable", "live", "failed_minimum", "graduated"].map(mode => ({
    args: ["auctions", "list", "--mode", mode, "--sort", "oldest", "--limit", "999"],
    path: `/api/v1/auctions?mode=${mode}&sort=oldest&limit=999`,
  })),
  { args: ["auction", active], path: `/api/v1/auctions/${active}` },
  { args: ["tokens", "list", "--limit", "0"], path: "/api/v1/tokens?limit=0" },
  { args: ["treasury", "security", treasury], path: `/api/v1/treasury-security/${treasury}` },
  ...[
    [active, "12.5", "3"],
    [closed, "12.5", "3"],
    [active, "  12.12345678901234567890123456789  ", "0003.000"],
    [active, "1e2", "3"],
  ].map(([id, amount, max_price]) => ({
    args: ["bids", "quote", "--auction", id, "--amount", amount, "--max-price", max_price],
    path: `/api/v1/auctions/${id}/bid-quote`, body: { amount, max_price },
  })),
  { args: ["auction", "00000000-0000-4000-8000-000000000000"], path: "/api/v1/auctions/00000000-0000-4000-8000-000000000000" },
  { args: ["treasury", "security", "invalid"], path: "/api/v1/treasury-security/invalid" },
];
const run = promisify(execFile);
const results = [];
for (const test of cases) {
  const response = await fetch(new URL(test.path, origin), {
    method: test.body ? "POST" : "GET",
    headers: { accept: "application/json", ...(test.body ? { "content-type": "application/json" } : {}) },
    body: test.body ? JSON.stringify(test.body) : undefined,
    credentials: "omit", redirect: "error",
  });
  const body = await response.json();
  let actual;
  try {
    actual = { ...await run(process.execPath, [resolve(root, "bin/autolaunch.js"), ...test.args, "--json"], {
      cwd: root, env: { ...process.env, AUTOLAUNCH_BASE_URL: origin.origin }, timeout: 20_000,
    }), code: 0 };
  } catch (error) {
    if (typeof error.code !== "number") throw error;
    actual = error;
  }
  if (response.ok) {
    assert.equal(actual.code, 0, actual.stderr);
    assert.deepEqual(JSON.parse(actual.stdout), { ok: true, status: response.status, body });
  } else {
    assert.equal(actual.code, 1);
    assert.deepEqual(JSON.parse(actual.stdout), { ok: false, status: response.status, body });
  }
  results.push({ command: test.args, status: response.status, body });
}
const quote = results.find(item => item.command[0] === "bids" && item.command[3] === active);
assert.equal(quote.body.data.estimated_tokens_if_end_now, "5");
assert.ok(results.find(item => item.command[0] === "bids" && item.command[3] === closed).body.data.warnings.includes("auction_not_biddable"));
const report = results.find(item => item.command[0] === "treasury").body.data;
assert.equal(report.classification, "supported_safe");
assert.equal(report.verification_state, "awaiting_current_chain_confirmation");
assert.equal(report.verification_reason, "projector_refresh_not_integrated");
await writeFile(resolve(evidenceDir, "results.json"), JSON.stringify(results, null, 2));
console.log(`${results.length} real HTTP/CLI comparisons passed. Evidence: ${evidenceDir}`);
