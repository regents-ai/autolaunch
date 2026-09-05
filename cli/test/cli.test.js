import assert from "node:assert/strict";
import {test} from "node:test";
import {fileURLToPath} from "node:url";
import {fixture, invoke, installed} from "./helpers.js";
const root = fileURLToPath(new URL("../", import.meta.url));
const source = fileURLToPath(new URL("../bin/autolaunch.js", import.meta.url));
const publicArgs = ["auctions", "list"];

test("packed CLI installs and preserves complete public HTTP results outside the checkout", async t => {
  const bin = await installed(t, root, "autolaunch");
  const api = await fixture(t);
  const discovery = await invoke(bin, ["commands", "list", "--json"]);
  assert.equal(discovery.code, 0);
  assert.ok(discovery.json.commands.length > 0);
  const help = await invoke(bin, ["--help", "--json"]);
  assert.equal(help.json.product, "autolaunch");
  const body = {data: {id: "900719925474099312345678", note: "證據🌳".repeat(20000), amount: "0.00000000000000000001", nullable: null}};
  api.respond({status: 200, body});
  const result = await invoke(bin, [...publicArgs, "--base-url", api.origin, "--json"]);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.json, {ok: true, status: 200, body});
  assert.equal(api.requests[0].headers.authorization, undefined);
  assert.equal(api.requests[0].headers.cookie, undefined);
  assert.equal(api.requests[0].headers["x-csrf-token"], undefined);
  const viaEnv = await invoke(bin, publicArgs, {AUTOLAUNCH_BASE_URL: api.origin});
  assert.equal(viaEnv.code, 0);
  assert.deepEqual(viaEnv.json.body, body);
});

test("HTTP failures preserve domain errors and retry guidance", async t => {
  const api = await fixture(t);
  for (const status of [400, 401, 403, 404, 422, 429, 500, 503]) {
    const body = {problem_code: "fixture_error", error: "Unchanged refusal", evidence: {value: null}};
    api.respond({status, body, headers: {"retry-after": "13"}});
    const result = await invoke(source, [...publicArgs, "--base-url", api.origin]);
    assert.equal(result.code, 1);
    assert.deepEqual(result.json, {ok: false, status, body, retry_after: "13"});
  }
});

test("malformed flags and identifiers fail before dispatch", async t => {
  const api = await fixture(t);
  const invalid = [
    [...publicArgs, "--unknown"], [...publicArgs, "--timeout-ms"],
    [...publicArgs, "--timeout-ms", "0"], [...publicArgs, "--timeout-ms", "Infinity"],
    [...publicArgs, "extra"], [...publicArgs, "--json", "--json"],
    [...publicArgs, "--json=false"], [...publicArgs, "--base-url", ""], ["auction", ".."],
  ];
  for (const args of invalid) {
    const result = await invoke(source, [...args, "--base-url", api.origin]);
    assert.equal(result.code, 2, JSON.stringify(args));
    assert.equal(result.json.error.code, "invalid_input");
  }
  assert.equal(api.requests.length, 0);
});

test("rejects credentialed or ambiguous origins and does not follow redirects", async t => {
  const api = await fixture(t);
  for (const base of ["https://user:secret@example.com", "https://example.com/path", "https://example.com?x=1", "http://example.com", "file:///tmp/file"]) {
    const result = await invoke(source, [...publicArgs, "--base-url", base]);
    assert.equal(result.code, 2);
    assert.ok(!result.stdout.includes("secret"));
  }
  api.respond({status: 302, headers: {location: `${api.origin}/redirect-target`}});
  const result = await invoke(source, [...publicArgs, "--base-url", api.origin]);
  assert.equal(result.code, 1);
  assert.equal(result.json.error.code, "network_error");
  assert.equal(api.requests.length, 1);
});

test("non-JSON failures and timeouts are explicit and never automatically retried", async t => {
  const api = await fixture(t);
  api.respond({status: 502, type: "text/html", text: "<p>Unavailable</p>", headers: {"retry-after": "17"}});
  const result = await invoke(source, [...publicArgs, "--base-url", api.origin]);
  assert.equal(result.code, 1);
  assert.equal(result.json.status, 502);
  assert.equal(result.json.error.code, "invalid_response");
  assert.equal(result.json.body_text, "<p>Unavailable</p>");
  assert.equal(result.json.retry_after, "17");
  api.respond({hang: true});
  const timeout = await invoke(source, [...publicArgs, "--base-url", api.origin, "--timeout-ms", "100"]);
  assert.equal(timeout.code, 1);
  assert.equal(timeout.json.error.code, "timeout");
  assert.equal(api.requests.length, 2);
});
