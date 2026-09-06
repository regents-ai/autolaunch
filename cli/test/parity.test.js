import assert from "node:assert/strict";
import {test} from "node:test";
import {fileURLToPath} from "node:url";
import {fixture, invoke} from "./helpers.js";

const bin = fileURLToPath(new URL("../bin/autolaunch.js", import.meta.url));

test("all five public commands match existing WebMCP requests and domain results", async t => {
  const api = await fixture(t);
  const registered = [];
  globalThis.document = {modelContext: {registerTool: async tool => { registered.push(tool); }}};
  globalThis.window = {location: {origin: api.origin}, addEventListener() {}};
  t.after(() => { delete globalThis.document; delete globalThis.window; });
  const {installPublicTools} = await import("../../platform/assets/js/public_tools.ts");
  installPublicTools();
  const id = "a12ee155-c71b-4107-87fd-dab8c7e00001";
  const address = "0x9999999999999999999999999999999999999999";
  const cases = [
    ["autolaunch_auctions", {}, ["auctions", "list"]],
    ...["all", "biddable", "live", "failed_minimum", "graduated"].map(mode => ["autolaunch_auctions", {mode, sort: "oldest", limit: 999}, ["auctions", "list", "--mode", mode, "--sort", "oldest", "--limit", "999"]]),
    ["autolaunch_auctions", {after: "cursor+/資料=="}, ["auctions", "list", "--after", "cursor+/資料=="]],
    ["autolaunch_tokens", {after: "cursor+/資料=="}, ["tokens", "list", "--after", "cursor+/資料=="]],
    ["autolaunch_auction", {id}, ["auction", id]],
    ["autolaunch_tokens", {limit: 0}, ["tokens", "list", "--limit", "0"]],
    ["autolaunch_treasury", {address}, ["treasury", "security", address]],
    ["autolaunch_bid_quote", {id, amount: " 12.12345678901234567890123456789 ", max_price: "0003.000"}, ["bids", "quote", "--auction", id, "--amount", " 12.12345678901234567890123456789 ", "--max-price", "0003.000"]],
  ];
  const body = {pagination: {has_more: true, next_cursor: "cursor+/資料=="}, data: {id, summary: "資料🌳", amount: "12.12345678901234567890123456789", warnings: ["auction_not_biddable"], treasury_security: {classification: "supported_safe", verification_state: "awaiting_current_chain_confirmation", verification_reason: "projector_refresh_not_integrated"}}};
  for (const [name, input, args] of cases) {
    api.respond({status: 200, body});
    const browser = await registered.find(tool => tool.name === name).execute(input, {signal: new AbortController().signal});
    const result = await invoke(bin, [...args, "--base-url", api.origin]);
    assert.equal(result.code, 0);
    assert.deepEqual(result.json, browser);
    const [browserRequest, cliRequest] = api.requests.slice(-2);
    assert.equal(cliRequest.method, browserRequest.method);
    assert.deepEqual(cliRequest.body, browserRequest.body);
    assert.equal(new URL(cliRequest.path, api.origin).href, new URL(browserRequest.path, api.origin).href.replace(/\?$/, ""));
  }
  for (const status of [400, 404]) {
    api.respond({status, body: {error: {code: status === 404 ? "not_found" : "invalid_request", message: "Fixture refusal"}}});
    const browser = await registered.find(tool => tool.name === "autolaunch_auction").execute({id}, {signal: new AbortController().signal});
    const cli = await invoke(bin, ["auction", id, "--base-url", api.origin]);
    assert.equal(cli.code, 1);
    assert.deepEqual(cli.json, browser);
  }
});
