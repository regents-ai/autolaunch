import {createWalletClient, custom, defineChain, getAddress, type Address, type Hash, type Hex, type WalletClient} from "viem"
import {getCapabilities, sendCalls, waitForCallsStatus} from "viem/actions"

import type {EthereumProvider, SelectedWallet} from "./connected_wallet"

/** The chain a step goes to, as the server names it for the wallet's prompt. */
export type StepChain = {chain_id: number; name: string; rpc_url: string}

/** One transaction a button sends, built on the server. */
export type TransactionStep = {kind: "transaction"; step: string; to: Address; data: Hex; value: Hex}

export type Step = TransactionStep

/** Nothing reached the wallet's send; the reason picks the words the server shows. */
export class NothingSent extends Error {
  constructor(readonly reason: "step_unknown" | "wallet_unavailable" | "network_mismatch") {
    super(reason)
  }
}

export type Failure = NothingSent["reason"] | "wallet_declined" | "insufficient_funds" | "send_unconfirmed"

/**
 * Sends one transaction from the signed-in wallet. Chain and account are read
 * again on every press, and `eth_chainId` is the last read before the send, so a
 * wallet that changes network part-way is refused before it sees the transaction.
 */
export async function sendStep(
  chain: StepChain,
  signer: Address,
  step: TransactionStep,
  wallet: () => SelectedWallet | null,
  sending: () => void,
): Promise<Hash> {
  const provider = await ready(chain, signer, wallet)

  sending()
  const hash = await provider.request({
    method: "eth_sendTransaction",
    params: [{
      from: getAddress(signer),
      to: getAddress(step.to),
      data: step.data,
      value: step.value,
      // A wallet that checks it refuses the send if it moved off the chain after the read above.
      chainId: `0x${chain.chain_id.toString(16)}`,
    }],
  })
  if (typeof hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
    throw new Error("The wallet did not return a transaction hash.")
  }
  return hash as Hash
}

/**
 * Sends every step in one atomic batch (EIP-5792 `wallet_sendCalls` with
 * `atomicRequired`), after the same chain and account checks as one step, and
 * returns the wallet's id for the batch. A wallet that cannot send them
 * atomically must refuse rather than send them one by one.
 */
export async function sendSteps(
  chain: StepChain,
  signer: Address,
  steps: TransactionStep[],
  wallet: () => SelectedWallet | null,
  sending: () => void,
): Promise<string> {
  const provider = await ready(chain, signer, wallet)

  sending()
  const {id} = await sendCalls(client(provider, signer), {
    chain: viemChain(chain),
    calls: steps.map(step => ({to: getAddress(step.to), data: step.data, value: BigInt(step.value)})),
    forceAtomic: true,
  })
  return id
}

/**
 * Whether the wallet says it can send calls together, atomically, on the
 * chain (EIP-5792 `wallet_getCapabilities`: `atomic` is "supported", or
 * "ready" for an account it would upgrade first). A wallet that does not
 * answer the question cannot.
 */
export async function sendsAtomically(chain: StepChain, signer: Address, provider: EthereumProvider): Promise<boolean> {
  try {
    const capabilities = await getCapabilities(client(provider, signer), {account: getAddress(signer), chainId: chain.chain_id})
    const status = (capabilities as {atomic?: {status?: unknown}} | undefined)?.atomic?.status
    return status === "supported" || status === "ready"
  } catch {
    return false
  }
}

/**
 * Waits for the wallet's own report on a batch it took (EIP-5792
 * `wallet_getCallsStatus`, asked every quarter second for up to three
 * minutes): whether it landed, and the transactions its receipts name.
 * `undefined` when the wallet gave no final answer in that time, or when
 * `stop` is aborted (the page left), which ends the asking at the next answer.
 */
export async function landedCalls(
  signer: Address,
  provider: EthereumProvider,
  id: string,
  stop: AbortSignal,
): Promise<{status: "success" | "failure"; hashes: Hash[]} | undefined> {
  try {
    const {status, receipts} = await waitForCallsStatus(client(provider, signer), {
      id,
      pollingInterval: 250,
      timeout: 180_000,
      status: ({statusCode}) => stop.aborted || statusCode === 200 || statusCode >= 300,
    })
    if (stop.aborted || (status !== "success" && status !== "failure")) return undefined
    return {status, hashes: (receipts ?? []).map(receipt => receipt.transactionHash)}
  } catch {
    return undefined
  }
}

/** The wallet refused the batch because it cannot send these calls atomically on this chain. */
export function refusedAtomic(error: unknown): boolean {
  // EIP-5792: 5700 a required capability, 5710 the chain, 5760 atomicity; EIP-1193 4200 the method.
  return [4200, 5700, 5710, 5760].some(code => hasCode(error, code)) ||
    causes(error).some(e => (e as {name?: unknown}).name === "AtomicityNotSupportedError")
}

const client = (provider: EthereumProvider, signer: Address): WalletClient =>
  createWalletClient({account: getAddress(signer), transport: custom(provider)})

// The step's chain as viem names one; the wallet already switched to it.
const viemChain = (chain: StepChain) =>
  defineChain({
    id: chain.chain_id,
    name: chain.name,
    nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
    rpcUrls: {default: {http: [chain.rpc_url]}},
  })

/** Why a press ended without a hash. After `sending`, the wallet may have sent it. */
export function failure(sending: boolean, error: unknown): Failure {
  if (!sending) return error instanceof NothingSent ? error.reason : "wallet_unavailable"
  // The wallet priced it and the chain refused it (code 3, or these words): it
  // can't be sent as it stands, which is not the person declining.
  if (hasCode(error, 3) || hasMessage(error, /execution reverted/i)) return "step_unknown"
  if (hasCode(error, 4001)) return "wallet_declined"
  // No EIP-1193 code names this; wallets and nodes all say it in these words.
  return hasMessage(error, /insufficient funds/i) ? "insufficient_funds" : "send_unconfirmed"
}

// The wallet is on the step's chain and account, and still the one Privy holds.
async function ready(
  chain: StepChain,
  signer: Address,
  wallet: () => SelectedWallet | null,
): Promise<EthereumProvider> {
  const selected = wallet()
  if (!selected) throw new NothingSent("wallet_unavailable")
  const {provider} = selected

  if ((await chainId(provider)) !== chain.chain_id) await switchChain(provider, chain)

  const [account] = await accounts(provider)
  if (!account || getAddress(account) !== getAddress(signer)) throw new NothingSent("wallet_unavailable")
  if ((await chainId(provider)) !== chain.chain_id) throw new NothingSent("network_mismatch")
  // Privy may have swapped the wallet during those reads; this check makes no request.
  if (wallet()?.provider !== provider) throw new NothingSent("wallet_unavailable")
  return provider
}

async function switchChain(provider: EthereumProvider, chain: StepChain): Promise<void> {
  const chainId = `0x${chain.chain_id.toString(16)}`
  try {
    try {
      await provider.request({method: "wallet_switchEthereumChain", params: [{chainId}]})
    } catch (error) {
      if (!hasCode(error, 4902)) throw error
      await provider.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId,
          chainName: chain.name,
          nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
          rpcUrls: [chain.rpc_url],
        }],
      })
      await provider.request({method: "wallet_switchEthereumChain", params: [{chainId}]})
    }
  } catch {
    throw new NothingSent("network_mismatch")
  }
}

async function chainId(provider: EthereumProvider): Promise<number> {
  const value = await provider.request({method: "eth_chainId"})
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value) ? Number(BigInt(value)) : -1
}

async function accounts(provider: EthereumProvider): Promise<string[]> {
  const value = await provider.request({method: "eth_accounts"})
  return Array.isArray(value) ? value.filter((a): a is string => typeof a === "string") : []
}

// Wallets wrap the EIP-1193 error in `cause` chains of their own.
function hasCode(error: unknown, code: number): boolean {
  return causes(error).some(e => (e as {code?: unknown}).code === code)
}

function hasMessage(error: unknown, words: RegExp): boolean {
  return causes(error).some(e => {
    const message = (e as {message?: unknown}).message
    return typeof message === "string" && words.test(message)
  })
}

function causes(error: unknown): object[] {
  const chain: object[] = []
  for (let e = error; e && typeof e === "object" && chain.length < 8; e = (e as {cause?: unknown}).cause) chain.push(e)
  return chain
}
