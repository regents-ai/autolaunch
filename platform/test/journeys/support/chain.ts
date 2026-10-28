import {readFileSync} from "node:fs"
import {decodeEventLog, encodeFunctionData, parseAbi, type Abi, type Hex} from "viem"

// The copy of Base the stack runs (test/journeys/support/base_fork.py). Every
// write here is on that copy only.
export async function rpc(method: string, params: unknown[] = []): Promise<any> {
  const response = await fetch(process.env.ANVIL_RPC!, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({jsonrpc: "2.0", id: 1, method, params}),
  })
  const reply = await response.json()
  if (reply.error) throw Object.assign(new Error(`${method}: ${reply.error.message}`), {code: reply.error.code})
  return reply.result
}

export async function blockNumber(): Promise<number> {
  return Number(BigInt(await rpc("eth_blockNumber")))
}

/** Mines blocks until the head is at least `block`. */
export async function mineTo(block: number) {
  const head = await blockNumber()
  if (block > head) await rpc("anvil_mine", [`0x${(block - head).toString(16)}`])
}

export async function receipt(hash: string): Promise<any> {
  for (let i = 0; i < 120; i++) {
    const found = await rpc("eth_getTransactionReceipt", [hash])
    if (found) return found
    await new Promise(r => setTimeout(r, 250))
  }
  throw new Error(`no receipt for ${hash}`)
}

/** Sends from any account on the copy, impersonated, and requires success. */
export async function sendAs(from: string, to: string, data: Hex, value = "0x0") {
  await rpc("anvil_impersonateAccount", [from])
  await rpc("anvil_setBalance", [from, "0x56bc75e2d63100000"])
  const hash = await rpc("eth_sendTransaction", [{from, to, data, value, gas: "0x2dc6c0"}])
  await rpc("anvil_stopImpersonatingAccount", [from])
  const mined = await receipt(hash)
  if (mined.status !== "0x1") throw new Error(`a send from ${from} to ${to} reverted`)
  return mined
}

export async function call(to: string, data: Hex): Promise<Hex> {
  return rpc("eth_call", [{to, data}, "latest"])
}

/** The Memestock settings file the site runs with, for its addresses and ABIs. */
export function memestock(): {addresses: Record<string, string>; abis: Record<string, Abi>} {
  return JSON.parse(readFileSync(`${process.env.STACK_STATE}/base-memestock.json`, "utf8"))
}

const SAFE = "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"
const erc20 = parseAbi([
  "function mint(address to, uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address owner) view returns (uint256)",
])

/** Gives `wallet` stand-in stock on the copy, as the Safe mints it there. */
export async function mintStock(stock: string, wallet: string, units: bigint) {
  await sendAs(SAFE, stock, encodeFunctionData({abi: erc20, functionName: "mint", args: [wallet as Hex, units]}))
}

export async function balanceOf(token: string, owner: string): Promise<bigint> {
  return BigInt(await call(token, encodeFunctionData({abi: erc20, functionName: "balanceOf", args: [owner as Hex]})))
}

/** The launchpad's StockLaunchCreated in a launch receipt, decoded with the site's own ABI. */
export function launchCreated(mined: any): Record<string, any> {
  const abi = memestock().abis.launchpad
  for (const log of mined.logs) {
    try {
      const event = decodeEventLog({abi, data: log.data, topics: log.topics})
      if (event.eventName === "StockLaunchCreated") return event.args as Record<string, any>
    } catch {
      // another contract's event
    }
  }
  throw new Error("the receipt has no StockLaunchCreated")
}
