#!/usr/bin/env node
// Two-door JSON-RPC proxy in front of the preview chain's Anvil.
//
//   public door   filtered: an allowlist of read methods plus eth_sendRawTransaction,
//                 bounded body size, bounded eth_getLogs ranges, CORS for wallets and browsers
//   private door  unfiltered: every method Anvil accepts, for the website and the controllers
//
// Both doors forward to the same Anvil, which binds only to localhost inside the machine.
// Dependency-free; Node 22.

import http from "node:http";
import { pathToFileURL } from "node:url";

export const LOCAL_CHAIN_ID = "0x7a69"; // 31337

export const PUBLIC_METHODS = new Set([
  "eth_chainId",
  "eth_blockNumber",
  "eth_getBalance",
  "eth_getCode",
  "eth_getStorageAt",
  "eth_call",
  "eth_estimateGas",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_feeHistory",
  "eth_getTransactionCount",
  "eth_getBlockByNumber",
  "eth_getBlockByHash",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  "eth_getLogs",
  "eth_sendRawTransaction",
  "eth_syncing",
  "net_version",
  "web3_clientVersion",
]);

export const MAX_BODY_BYTES = 512 * 1024;
export const MAX_BATCH_REQUESTS = 100;
export const MAX_GET_LOGS_BLOCKS = 10_000n;
export const UPSTREAM_TIMEOUT_MS = 30_000;

const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type",
  "access-control-max-age": "86400",
};

const HEX_QUANTITY = /^0x[0-9a-fA-F]{1,64}$/;
const HEAD_TAGS = new Set(["latest", "pending", "safe", "finalized"]);

class Refusal extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function configFromEnv(env = process.env) {
  return {
    anvilUrl: env.FORK_ANVIL_URL ?? "http://127.0.0.1:8546",
    publicHost: env.FORK_PUBLIC_HOST ?? "0.0.0.0",
    publicPort: Number(env.FORK_PUBLIC_PORT ?? 8545),
    privateHost: env.FORK_PRIVATE_HOST ?? "fly-local-6pn",
    privatePort: Number(env.FORK_PRIVATE_PORT ?? 8547),
    maxBodyBytes: MAX_BODY_BYTES,
    maxBatchRequests: MAX_BATCH_REQUESTS,
    maxGetLogsBlocks: MAX_GET_LOGS_BLOCKS,
    upstreamTimeoutMs: UPSTREAM_TIMEOUT_MS,
  };
}

function logLine(record) {
  process.stdout.write(`${JSON.stringify({ t: new Date().toISOString(), ...record })}\n`);
}

function rpcError(id, code, message) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message } };
}

function send(response, status, document, extraHeaders = {}) {
  const body = Buffer.from(JSON.stringify(document));
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": body.length,
    ...CORS_HEADERS,
    ...extraHeaders,
  });
  response.end(body);
}

function readBody(request, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        chunks.length = 0;
        request.pause();
        reject(new Refusal(413, -32600, `request body exceeds ${maxBytes} bytes`));
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", (error) => reject(new Refusal(400, -32600, error.message)));
  });
}

function parseQuantity(value, label) {
  if (typeof value !== "string" || !HEX_QUANTITY.test(value)) {
    throw new Refusal(200, -32602, `${label} must be a hex quantity or a block tag`);
  }
  return BigInt(value);
}

export class Upstream {
  constructor(url, timeoutMs) {
    this.url = new URL(url);
    this.timeoutMs = timeoutMs;
    this.agent = new http.Agent({ keepAlive: true, maxSockets: 64 });
  }

  forward(body) {
    return new Promise((resolve, reject) => {
      const request = http.request(
        this.url,
        {
          method: "POST",
          agent: this.agent,
          headers: { "content-type": "application/json", "content-length": body.length },
          timeout: this.timeoutMs,
        },
        (response) => {
          const chunks = [];
          response.on("data", (chunk) => chunks.push(chunk));
          response.on("end", () =>
            resolve({ status: response.statusCode ?? 502, body: Buffer.concat(chunks) }),
          );
          response.on("error", () => reject(new Refusal(502, -32603, "anvil response failed")));
        },
      );
      request.on("timeout", () => {
        request.destroy();
        reject(new Refusal(504, -32603, "anvil did not answer in time"));
      });
      request.on("error", () => reject(new Refusal(502, -32603, "anvil is unavailable")));
      request.end(body);
    });
  }

  async call(method, params = []) {
    const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }));
    const { body: answer } = await this.forward(body);
    let document;
    try {
      document = JSON.parse(answer.toString("utf8"));
    } catch {
      throw new Refusal(502, -32603, "anvil returned invalid JSON");
    }
    if (document.error) {
      throw new Refusal(502, -32603, `anvil ${method} failed: ${document.error.message}`);
    }
    return document.result;
  }
}

async function checkGetLogsRange(params, upstream, maxBlocks) {
  const filter = Array.isArray(params) ? params[0] : undefined;
  if (filter === null || typeof filter !== "object" || Array.isArray(filter)) {
    throw new Refusal(200, -32602, "eth_getLogs expects a filter object");
  }
  if (filter.blockHash !== undefined) return;
  const { fromBlock, toBlock } = filter;
  if (fromBlock === undefined || HEAD_TAGS.has(fromBlock)) return;
  if (fromBlock === "earliest") {
    throw new Refusal(200, -32005, `eth_getLogs from earliest is not allowed; ranges are capped at ${maxBlocks} blocks`);
  }
  const from = parseQuantity(fromBlock, "fromBlock");
  let to;
  if (toBlock === undefined || HEAD_TAGS.has(toBlock)) {
    to = parseQuantity(await upstream.call("eth_blockNumber"), "head");
  } else if (toBlock === "earliest") {
    to = 0n;
  } else {
    to = parseQuantity(toBlock, "toBlock");
  }
  if (to >= from && to - from + 1n > maxBlocks) {
    throw new Refusal(200, -32005, `eth_getLogs range exceeds ${maxBlocks} blocks`);
  }
}

function requestsOf(document, maxBatch) {
  const list = Array.isArray(document) ? document : [document];
  if (list.length === 0) throw new Refusal(200, -32600, "empty batch");
  if (list.length > maxBatch) throw new Refusal(200, -32600, `batch exceeds ${maxBatch} requests`);
  for (const entry of list) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
      throw new Refusal(200, -32600, "each request must be an object");
    }
    if (typeof entry.method !== "string" || entry.method.length === 0) {
      throw new Refusal(200, -32600, "each request needs a method name");
    }
  }
  return list;
}

async function admit(requests, { filtered, upstream, maxGetLogsBlocks }) {
  if (!filtered) return;
  for (const { method, params } of requests) {
    if (!PUBLIC_METHODS.has(method)) {
      throw new Refusal(200, -32601, `method not allowed on the public door: ${method}`);
    }
    if (method === "eth_getLogs") await checkGetLogsRange(params, upstream, maxGetLogsBlocks);
  }
}

function clientAddress(request) {
  return request.headers["fly-client-ip"] ?? request.socket.remoteAddress ?? "";
}

export function createDoor({ name, filtered, upstream, config, log = logLine }) {
  return http.createServer(async (request, response) => {
    const started = process.hrtime.bigint();
    const record = { door: name, ip: clientAddress(request), http: request.method };
    const finish = (status) => {
      record.status = status;
      record.ms = Number((process.hrtime.bigint() - started) / 1_000_000n);
      log(record);
    };

    if (request.method === "OPTIONS") {
      response.writeHead(204, CORS_HEADERS);
      response.end();
      finish(204);
      return;
    }

    if (request.method === "GET" && request.url === "/healthz") {
      try {
        const chainId = await upstream.call("eth_chainId");
        if (chainId !== LOCAL_CHAIN_ID) throw new Refusal(503, -32603, `anvil answers as ${chainId}`);
        send(response, 200, { ok: true, door: name, chainId });
        finish(200);
      } catch (error) {
        record.refused = error.message;
        send(response, 503, { ok: false, door: name, error: error.message });
        finish(503);
      }
      return;
    }

    if (request.method !== "POST") {
      send(response, 405, rpcError(null, -32600, "JSON-RPC over POST only"), { allow: "POST, OPTIONS" });
      finish(405);
      return;
    }

    let id = null;
    try {
      const body = await readBody(request, config.maxBodyBytes);
      let document;
      try {
        document = JSON.parse(body.toString("utf8"));
      } catch {
        throw new Refusal(200, -32700, "invalid JSON");
      }
      const requests = requestsOf(document, config.maxBatchRequests);
      id = Array.isArray(document) ? null : (document.id ?? null);
      record.n = requests.length;
      record.methods = requests.map((entry) => entry.method);
      await admit(requests, { filtered, upstream, maxGetLogsBlocks: config.maxGetLogsBlocks });
      const answer = await upstream.forward(body);
      response.writeHead(answer.status, {
        "content-type": "application/json",
        "content-length": answer.body.length,
        ...CORS_HEADERS,
      });
      response.end(answer.body);
      finish(answer.status);
    } catch (error) {
      const refusal = error instanceof Refusal ? error : new Refusal(500, -32603, "proxy failure");
      record.refused = refusal.message;
      if (!response.headersSent) {
        const headers = refusal.status === 413 ? { connection: "close" } : {};
        // An oversize body is never read to the end: answer, then drop the connection.
        if (refusal.status === 413) response.on("finish", () => request.socket.destroy());
        send(response, refusal.status, rpcError(id, refusal.code, refusal.message), headers);
      }
      finish(refusal.status);
    }
  });
}

export function createServers(config, log = logLine) {
  const upstream = new Upstream(config.anvilUrl, config.upstreamTimeoutMs);
  return {
    publicServer: createDoor({ name: "public", filtered: true, upstream, config, log }),
    privateServer: createDoor({ name: "private", filtered: false, upstream, config, log }),
  };
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => resolve(server.address()));
  });
}

export async function start(config = configFromEnv()) {
  const { publicServer, privateServer } = createServers(config);
  const publicAddress = await listen(publicServer, config.publicPort, config.publicHost);
  const privateAddress = await listen(privateServer, config.privatePort, config.privateHost);
  logLine({ event: "listening", door: "public", ...publicAddress, filtered: true, anvil: config.anvilUrl });
  logLine({ event: "listening", door: "private", ...privateAddress, filtered: false, anvil: config.anvilUrl });
  const shutdown = (signal) => {
    logLine({ event: "shutdown", signal });
    publicServer.close();
    privateServer.close();
    setTimeout(() => process.exit(0), 2_000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
  return { publicServer, privateServer };
}

const invokedDirectly = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) {
  start().catch((error) => {
    logLine({ event: "fatal", error: error.message });
    process.exit(1);
  });
}
