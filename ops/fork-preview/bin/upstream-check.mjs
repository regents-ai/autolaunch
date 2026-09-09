#!/usr/bin/env node
// Container-side helper for run-fork.sh: proves the upstream answers as Base (8453) and prints
// its head block number in decimal. Reads the upstream URL from FORK_UPSTREAM_RPC_URL and never
// prints it, because on Fly it carries the paid provider key.

const BASE_CHAIN_ID = "0x2105";

const url = process.env.FORK_UPSTREAM_RPC_URL;
if (!url) {
  process.stderr.write("FORK_UPSTREAM_RPC_URL is not set\n");
  process.exit(2);
}

async function call(method) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: [] }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) throw new Error(`upstream answered HTTP ${response.status} to ${method}`);
  const document = await response.json();
  if (document.error) throw new Error(`upstream ${method} failed: ${document.error.message}`);
  return document.result;
}

try {
  const chainId = await call("eth_chainId");
  if (chainId !== BASE_CHAIN_ID) throw new Error(`upstream is chain ${chainId}, not Base ${BASE_CHAIN_ID}`);
  const head = await call("eth_blockNumber");
  if (!/^0x[0-9a-fA-F]+$/.test(head)) throw new Error("upstream returned an invalid block number");
  process.stdout.write(`${BigInt(head).toString(10)}\n`);
} catch (error) {
  process.stderr.write(`upstream check failed: ${error.message}\n`);
  process.exit(1);
}
