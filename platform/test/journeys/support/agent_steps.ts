import type {Page} from "@playwright/test"
import {decodeFunctionResult, encodeFunctionData, type Abi, type Hex} from "viem"
import type {Agent} from "./agent"
import {call, memestock, receipt, revstake} from "./chain"
import {expect} from "./person"
import {call as rhCall, clockTo, deployment, receipt as rhReceipt, rh} from "./robinhood"

// What the agent finish and staking journeys share: asking one preparation both ways, sending
// the steps it gives from the person's wallet, and reading a launch's own record on its chain.

export type Step = {kind: string; step: string; to: string; data: string; value: string}

/** One transaction the person's wallet sent, as the journey's evidence keeps it. */
export type Landed = {label: string; step: string; chain_id: number; hash: string; status: string; block: number}

const BASE = 31_337

/**
 * One preparation both ways: the signed route `path` with `body`, then the hosted tool `name`
 * with `input`. The tool answers as the route's body does: its result under `data`, or its
 * refusal's error under `error`.
 */
export async function bothWays(agent: Agent, path: string, body: object, name: string, input: object) {
  const route = agent.signed("POST", path, body)
  const [hosted] = await agent.mcp([{name, input}])
  const tool = hosted.isError ? JSON.parse(hosted.content[0].text) : {data: hosted.structuredContent}
  return {route, tool}
}

/** The steps, both ways alike, read at one block: nothing is mined between the two asks. */
export async function given(agent: Agent, path: string, body: object, name: string, input: object): Promise<any> {
  const {route, tool} = await bothWays(agent, path, body, name, input)
  expect(route.status, JSON.stringify(route.json)).toBe(200)
  expect(tool, "the hosted tool answers as the route does").toEqual(route.json)
  return route.json.data
}

/** A refusal, both ways alike: its status and code, and no steps. Answers the route's body. */
export async function refusedBoth(agent: Agent, path: string, body: object, name: string, input: object, status: number, code: string) {
  const {route, tool} = await bothWays(agent, path, body, name, input)
  expect({status: route.status, code: route.json.error?.code}, JSON.stringify(route.json)).toEqual({status, code})
  expect(route.json.data).toBeUndefined()
  expect(tool, "the hosted tool refuses as the route does").toEqual(route.json)
  return route.json
}

/**
 * The person's wallet, the injected one `page` holds, moves to the answer's chain and sends each
 * of its steps exactly as given, in order; each must land. Every send is kept in `log`.
 */
export async function sendSteps(page: Page, wallet: string, answer: {chain: {chain_id: number}; steps: Step[]}, label: string, log: Landed[]) {
  const chainId = answer.chain.chain_id
  await page.evaluate(
    id => (window as any).journeyWallet({method: "wallet_switchEthereumChain", params: [{chainId: id}]}),
    `0x${chainId.toString(16)}`,
  )
  const mined: any[] = []
  for (const step of answer.steps) {
    const hash: string = await page.evaluate(
      tx => (window as any).journeyWallet({method: "eth_sendTransaction", params: [tx]}),
      {from: wallet, to: step.to, data: step.data, value: step.value},
    )
    const landed = chainId === BASE ? await receipt(hash) : await rhReceipt(hash)
    log.push({label, step: step.step, chain_id: chainId, hash, status: landed.status, block: Number(BigInt(landed.blockNumber))})
    expect(landed.status, `${label}: ${step.step} lands`).toBe("0x1")
    mined.push(landed)
  }
  return mined
}

/** The site's listing of the auction of the launch named `symbol`, as the agent's own read tool finds it. */
export async function listedAuction(agent: Agent, symbol: string): Promise<any> {
  let found: any
  await expect.poll(async () => {
    const [answer] = await agent.mcp([{name: "autolaunch_auctions", input: {q: symbol}}])
    found = answer.structuredContent?.data?.find((auction: any) => auction.token_symbol === symbol)
    return found
  }, {message: `autolaunch_auctions lists ${symbol}`, timeout: 120_000, intervals: [5_000]}).toBeTruthy()
  return found
}

/** The site's listing of the token named `symbol`, as the agent's own read tool finds it. */
export async function listedToken(agent: Agent, symbol: string): Promise<any> {
  let found: any
  await expect.poll(async () => {
    const [answer] = await agent.mcp([{name: "autolaunch_tokens", input: {q: symbol}}])
    found = answer.structuredContent?.data?.find((token: any) => token.symbol === symbol)
    return found
  }, {message: `autolaunch_tokens lists ${symbol}`, timeout: 180_000, intervals: [5_000]}).toBeTruthy()
  return found
}

/**
 * The auction as the site's public API answers it. An answer without it fails the journey with
 * what the site sent, its status and body, so the failure says why.
 */
export async function record(id: string): Promise<any> {
  const answer = await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions/${id}`)
  const body = await answer.text()
  let data: any
  try {
    data = JSON.parse(body).data
  } catch {
    data = undefined
  }
  if (!answer.ok || !data) throw new Error(`GET /api/v1/auctions/${id} answered ${answer.status}: ${body.slice(0, 1_000)}`)
  return data
}

export type Venue = "memestock" | "revstake" | "robinhood"

async function read(venue: Venue, to: string, abi: Abi, functionName: string, args: unknown[]): Promise<any> {
  const data = encodeFunctionData({abi, functionName, args} as any) as Hex
  const answer = venue === "robinhood" ? await rhCall(to, data) : await call(to, data)
  return decodeFunctionResult({abi, functionName, data: answer} as any)
}

/**
 * A launch as its own contract records it on its chain: the Memestock launchpad's record of the
 * auction's launch (with its id), or the Revstake strategy's distribution of the auction. Each
 * holds the migration block finishing opens at and the launch's lifecycle. Also answers the
 * contract the finish goes to and the call it makes there.
 */
export async function launchRecord(venue: Venue, auction: string) {
  if (venue === "revstake") {
    const {addresses, abis} = revstake()
    const distribution = await read(venue, addresses.strategy, abis.strategy, "distribution", [auction])
    const migrate = encodeFunctionData({abi: abis.strategy, functionName: "migrate", args: [auction]} as any)
    return {...distribution, finisher: addresses.strategy.toLowerCase(), migrate}
  }
  const {address, abi} = venue === "robinhood"
    ? {address: deployment().addresses.stocks_launchpad, abi: deployment().abis.stocks_launchpad}
    : {address: memestock().addresses.launchpad, abi: memestock().abis.launchpad}
  const launchId = await read(venue, address, abi, "launchIdOfAuction", [auction])
  const launch = await read(venue, address, abi, "launches", [launchId])
  const migrate = encodeFunctionData({abi, functionName: "migrate", args: [launchId]} as any)
  return {...launch, launchId, finisher: address.toLowerCase(), migrate}
}

/**
 * Moves the Robinhood lab's block clock to `block` and mines one block. On Robinhood Chain the
 * clock is the rollup's own block, so it never moves without a new block; the lab sets it with
 * none, and the site's auction readers read each new block, so one is mined after.
 */
export async function clockStep(block: number) {
  await clockTo(block)
  await rh("evm_mine")
}

/** Writes a journey's evidence, its big numbers as text. */
export const evidenceText = (evidence: object) =>
  JSON.stringify(evidence, (_key, value) => (typeof value === "bigint" ? String(value) : value), 1)
