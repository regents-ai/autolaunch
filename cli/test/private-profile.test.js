import {test} from "node:test";
import assert from "node:assert/strict";
import {createServer} from "node:http";
import {spawn} from "node:child_process";
import {fileURLToPath} from "node:url";
const product = fileURLToPath(new URL("../", import.meta.url)).includes("autolaunch") ? "autolaunch" : "patchbay";
const pair = {access: "fixture.access.signature", identity: "fixture.identity.signature"};
const cli = (args, input = JSON.stringify(pair), env = {}) => new Promise(resolve => {
  const child = spawn(process.execPath, [fileURLToPath(new URL(`../bin/${product}.js`, import.meta.url)), ...args], {env: {...process.env, ...env}, stdio: ["pipe", "pipe", "pipe"]});
  let out = "", err = "";
  child.stdout.on("data", data => { out += data; }); child.stderr.on("data", data => { err += data; });
  child.on("close", code => resolve({code, out, err, result: JSON.parse(out)}));
  child.stdin.on("error", () => {}); child.stdin.end(input);
});

test("private profile commands send proof only in headers, use exact methods and never retry or reflect proof", async () => {
  const requests = [];
  let responseMode = "profile";
  const server = createServer(async (req, res) => {
    let body = ""; for await (const chunk of req) body += chunk;
    requests.push({method: req.method, path: req.url, headers: req.headers, body});
    if (responseMode === "redirect") { res.writeHead(302, {location: "/leak"}); return res.end(); }
    if (responseMode === "reflect") return res.end(JSON.stringify({error: {code: req.headers.authorization}}));
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({profile: {profile_id: "shared", display_name: "Person", wallet: {address: null, verified: false}, x: null}}));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const [op, method, suffix, flags] of [["get", "GET", "", []], ["sync", "POST", "/sync", []], ["update", "PATCH", "", ["--display-name", "Shared"]]]) {
      const result = await cli(["profile", op, ...flags, "--base-url", base]);
      assert.equal(result.code, 0); assert.equal(result.result.body.profile.profile_id, "shared");
      const request = requests.at(-1);
      assert.equal(request.method, method); assert.equal(request.path, `/api/v1/profile${suffix}`);
      assert.equal(request.headers.authorization, `Bearer ${pair.access}`);
      assert.equal(request.headers["privy-id-token"], pair.identity); assert.equal(request.headers.cookie, undefined);
      assert.ok(!result.out.includes(pair.access) && !result.err.includes(pair.identity));
    }
    const before = requests.length;
    for (const input of ["", "not JSON", JSON.stringify({access: pair.access}), JSON.stringify({...pair, cookie: "no"}), "x".repeat(70001)]) {
      assert.equal((await cli(["profile", "get", "--base-url", base], input)).code, 2);
    }
    assert.equal((await cli(["profile", "update", "--base-url", base])).code, 2);
    assert.equal(requests.length, before);
    for (responseMode of ["redirect", "reflect"]) {
      const failed = await cli(["profile", "sync", "--base-url", base]);
      assert.equal(failed.code, 1); assert.equal(failed.result.error.outcome_unknown, true);
      assert.ok(!failed.out.includes(pair.access) && !failed.err.includes(pair.identity));
    }
    assert.equal(requests.length, before + 2);
    const help = await cli(["profile", "get", "--help", "--json"], "not proof");
    assert.equal(help.code, 0); assert.equal(requests.length, before + 2);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
