import http from "node:http";
import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { LOCAL_CHAIN_ID, MAX_BODY_BYTES, PUBLIC_METHODS, createServers } from "./server.mjs";

// A stand-in for Anvil: records every method it is asked and answers a few of them.
const seen = [];
const fakeAnvil = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    const document = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const answer = (entry) => {
      seen.push(entry.method);
      const result =
        entry.method === "eth_chainId"
          ? LOCAL_CHAIN_ID
          : entry.method === "eth_blockNumber"
            ? "0x30d40" // 200,000
            : entry.method === "eth_getLogs"
              ? []
              : "0x1";
      return { jsonrpc: "2.0", id: entry.id ?? null, result };
    };
    const body = JSON.stringify(Array.isArray(document) ? document.map(answer) : answer(document));
    response.writeHead(200, { "content-type": "application/json" });
    response.end(body);
  });
});

let publicUrl;
let privateUrl;
let servers;

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

before(async () => {
  const anvilPort = await listen(fakeAnvil);
  servers = createServers(
    {
      anvilUrl: `http://127.0.0.1:${anvilPort}`,
      maxBodyBytes: MAX_BODY_BYTES,
      maxBatchRequests: 100,
      maxGetLogsBlocks: 10_000n,
      upstreamTimeoutMs: 5_000,
    },
    () => {},
  );
  publicUrl = `http://127.0.0.1:${await listen(servers.publicServer)}`;
  privateUrl = `http://127.0.0.1:${await listen(servers.privateServer)}`;
});

after(() => {
  servers.publicServer.close();
  servers.privateServer.close();
  fakeAnvil.close();
});

async function post(url, document, raw) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: raw ?? JSON.stringify(document),
  });
  const text = await response.text();
  return { status: response.status, headers: response.headers, body: text ? JSON.parse(text) : null };
}

const rpc = (method, params = [], id = 1) => ({ jsonrpc: "2.0", id, method, params });

test("an allowlisted method passes through the public door", async () => {
  seen.length = 0;
  const { status, body, headers } = await post(publicUrl, rpc("eth_chainId"));
  assert.equal(status, 200);
  assert.equal(body.result, LOCAL_CHAIN_ID);
  assert.equal(headers.get("access-control-allow-origin"), "*");
  assert.deepEqual(seen, ["eth_chainId"]);
});

test("every allowlisted method is admitted and nothing else is", async () => {
  for (const method of PUBLIC_METHODS) {
    if (method === "eth_getLogs") continue;
    const { body } = await post(publicUrl, rpc(method));
    assert.equal(body.error, undefined, `${method} should pass`);
  }
  for (const method of ["anvil_setBalance", "evm_mine", "hardhat_setCode", "debug_traceTransaction", "eth_sendTransaction", "eth_sendUnsignedTransaction", "personal_sign", "miner_start", "eth_accounts", "anvil_nodeInfo", "web3_sha3"]) {
    const { body } = await post(publicUrl, rpc(method));
    assert.equal(body.error?.code, -32601, `${method} should be refused`);
  }
});

test("anvil_impersonateAccount is refused on the public door with -32601 and never reaches Anvil", async () => {
  seen.length = 0;
  const { status, body } = await post(publicUrl, rpc("anvil_impersonateAccount", ["0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"], 7));
  assert.equal(status, 200);
  assert.equal(body.id, 7);
  assert.equal(body.error.code, -32601);
  assert.match(body.error.message, /anvil_impersonateAccount/);
  assert.deepEqual(seen, []);
});

test("a batch with one forbidden member is refused whole", async () => {
  seen.length = 0;
  const { body } = await post(publicUrl, [rpc("eth_chainId", [], 1), rpc("anvil_mine", ["0x1"], 2), rpc("eth_blockNumber", [], 3)]);
  assert.equal(Array.isArray(body), false);
  assert.equal(body.error.code, -32601);
  assert.match(body.error.message, /anvil_mine/);
  assert.deepEqual(seen, []);
});

test("a batch of allowlisted methods passes as an array", async () => {
  const { body } = await post(publicUrl, [rpc("eth_chainId", [], 1), rpc("eth_blockNumber", [], 2)]);
  assert.equal(body.length, 2);
  assert.equal(body[0].result, LOCAL_CHAIN_ID);
});

test("an oversize body is refused with 413", async () => {
  seen.length = 0;
  const padding = "0".repeat(MAX_BODY_BYTES);
  const { status, body } = await post(publicUrl, null, JSON.stringify(rpc("eth_call", [{ data: `0x${padding}` }])));
  assert.equal(status, 413);
  assert.equal(body.error.code, -32600);
  assert.deepEqual(seen, []);
});

test("eth_getLogs over more than 10,000 blocks is refused; a bounded range passes", async () => {
  const wide = await post(publicUrl, rpc("eth_getLogs", [{ fromBlock: "0x0", toBlock: "0x2711" }]));
  assert.equal(wide.body.error.code, -32005);
  const earliest = await post(publicUrl, rpc("eth_getLogs", [{ fromBlock: "earliest", toBlock: "latest" }]));
  assert.equal(earliest.body.error.code, -32005);
  const toHead = await post(publicUrl, rpc("eth_getLogs", [{ fromBlock: "0x0", toBlock: "latest" }]));
  assert.equal(toHead.body.error.code, -32005);
  const nearHead = await post(publicUrl, rpc("eth_getLogs", [{ fromBlock: "0x30000", toBlock: "latest" }]));
  assert.deepEqual(nearHead.body.result, []);
  const exact = await post(publicUrl, rpc("eth_getLogs", [{ fromBlock: "0x0", toBlock: "0x270f" }]));
  assert.deepEqual(exact.body.result, []);
  const byHash = await post(publicUrl, rpc("eth_getLogs", [{ blockHash: `0x${"ab".repeat(32)}` }]));
  assert.deepEqual(byHash.body.result, []);
  const malformed = await post(publicUrl, rpc("eth_getLogs", [{ fromBlock: "12", toBlock: "latest" }]));
  assert.equal(malformed.body.error.code, -32602);
});

test("malformed JSON-RPC is refused without reaching Anvil", async () => {
  seen.length = 0;
  assert.equal((await post(publicUrl, null, "{not json")).body.error.code, -32700);
  assert.equal((await post(publicUrl, { jsonrpc: "2.0", id: 1 })).body.error.code, -32600);
  assert.equal((await post(publicUrl, [])).body.error.code, -32600);
  assert.equal((await post(publicUrl, [1, 2])).body.error.code, -32600);
  assert.deepEqual(seen, []);
});

test("the public door answers CORS preflight and refuses other verbs", async () => {
  const preflight = await fetch(publicUrl, { method: "OPTIONS" });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-methods"), "POST, OPTIONS");
  const get = await fetch(`${publicUrl}/`);
  assert.equal(get.status, 405);
});

test("GET /healthz reports the chain id", async () => {
  const response = await fetch(`${publicUrl}/healthz`);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.chainId, LOCAL_CHAIN_ID);
});

test("the private door forwards anvil_* and a mixed batch unchanged", async () => {
  seen.length = 0;
  const single = await post(privateUrl, rpc("anvil_impersonateAccount", ["0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"]));
  assert.equal(single.status, 200);
  assert.equal(single.body.result, "0x1");
  const batch = await post(privateUrl, [rpc("anvil_setBalance", [], 1), rpc("evm_snapshot", [], 2)]);
  assert.equal(batch.body.length, 2);
  assert.deepEqual(seen, ["anvil_impersonateAccount", "anvil_setBalance", "evm_snapshot"]);
});

test("the private door still refuses bodies over the cap", async () => {
  const { status } = await post(privateUrl, null, JSON.stringify(rpc("anvil_setCode", [`0x${"0".repeat(MAX_BODY_BYTES)}`])));
  assert.equal(status, 413);
});
