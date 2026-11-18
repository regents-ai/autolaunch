import {readFileSync} from "node:fs"
import {decodeErrorResult, encodeFunctionData, parseAbi, type Abi, type Hex} from "viem"
import {rpcAt} from "./chain"

// The Robinhood lab the stack runs (contracts/robinhood-v2/bin/local-robinhood-lab.py): a blank
// Anvil, chain 31338, carrying the Robinhood launchpad, its bid adapter, USDG and fixture stocks.
// Its auctions keep time as Robinhood Chain's do, by ArbSys's arbBlockNumber(), which on the lab
// answers a number the lab sets (storage slot 0 of 0x…64) and never moves with its blocks. Every
// write here is on the lab only, from its unlocked development accounts.
export const rh = (method: string, params: unknown[] = []) => rpcAt(process.env.ROBINHOOD_RPC!, method, params)

const ARB_SYS = "0x0000000000000000000000000000000000000064"

export const erc20 = parseAbi([
  "function mint(address to, uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address owner) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
])

export const permit2 = parseAbi([
  "function approve(address token, address spender, uint160 amount, uint48 expiration)",
])

/** The Robinhood deployment description the site runs with, for its addresses and ABIs. */
export function deployment(): {chain_id: number; addresses: Record<string, string>; abis: Record<string, Abi>} {
  return JSON.parse(readFileSync(`${process.env.STACK_STATE}/robinhood.json`, "utf8"))
}

/** The lab's own record of its run: the account that deployed it and the fixture stocks it admits. */
export function lab(): {deployer: string; stocks: {symbol: string; address: string}[]} {
  return JSON.parse(readFileSync(process.env.ROBINHOOD_LAB_STATE!, "utf8"))
}

/** The block clock every lab auction keeps time by. */
export async function clock(): Promise<number> {
  return Number(BigInt(await rh("eth_call", [{to: ARB_SYS, data: "0xa3b1b31d"}, "latest"])))
}

/** Moves the block clock forward to `block`, as the lab's own advance does; never back. */
export async function clockTo(block: number) {
  const now = await clock()
  if (block < now) throw new Error(`the block clock is at ${now}, past ${block}`)
  await rh("anvil_setStorageAt", [ARB_SYS, "0x0", `0x${block.toString(16).padStart(64, "0")}`])
  if ((await clock()) !== block) throw new Error(`the block clock did not move to ${block}`)
}

export async function receipt(hash: string): Promise<any> {
  for (let i = 0; i < 120; i++) {
    const found = await rh("eth_getTransactionReceipt", [hash])
    if (found) return found
    await new Promise(r => setTimeout(r, 250))
  }
  throw new Error(`no receipt for ${hash} on the Robinhood lab`)
}

/** Sends from one of the lab's unlocked accounts and requires success. */
export async function sendFrom(from: string, to: string, data: Hex) {
  const mined = await receipt(await rh("eth_sendTransaction", [{from, to, data, gas: "0x2dc6c0"}]))
  if (mined.status !== "0x1") throw new Error(`a send from ${from} to ${to} reverted on the Robinhood lab`)
  return mined
}

export async function call(to: string, data: Hex, from?: string): Promise<Hex> {
  return rh("eth_call", [{to, data, ...(from ? {from} : {})}, "latest"])
}

/** The name of the error `to` reverts a call from `from` with, decoded with `abi`. */
export async function refusal(to: string, data: Hex, from: string, abi: Abi): Promise<string> {
  try {
    await call(to, data, from)
  } catch (error: any) {
    return decodeErrorResult({abi, data: error.data}).errorName
  }
  throw new Error(`the call to ${to} from ${from} did not revert`)
}

/** Gives `wallet` `units` of a lab token (USDG or a fixture stock), minted by the lab's deployer. */
export async function mint(token: string, wallet: string, units: bigint) {
  await sendFrom(lab().deployer, token, encodeFunctionData({abi: erc20, functionName: "mint", args: [wallet as Hex, units]}))
}

export async function balanceOf(token: string, owner: string): Promise<bigint> {
  return BigInt(await call(token, encodeFunctionData({abi: erc20, functionName: "balanceOf", args: [owner as Hex]})))
}
