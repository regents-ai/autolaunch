import {createWalletClient, custom, getAddress, type Address, type Hash, type Hex} from "viem"
import {base} from "viem/chains"

import type {EthereumProvider, SelectedWallet} from "./connected_wallet"

export type SubjectStepName = "approval" | "action"

export type SubjectStep = {
  step: SubjectStepName
  to: Address
  data: Hex
}

/**
 * The reviewed sequence exactly as the server wrote it. The browser holds it so
 * it can check that what it is asked to send really belongs to this operation,
 * and never so it can build a transaction of its own: there is no encoder here.
 */
export type SubjectWalletOperation = {
  action_id: string
  subject_id: string
  signer: Address
  chain_id: number
  terminal: boolean
  steps: SubjectStep[]
}

export type SubjectWalletClients = {
  addresses(): Promise<Address[]>
  chainId(): Promise<number>
  switchToBase(): Promise<void>
  send(request: {account: Address; to: Address; data: Hex; value: bigint}): Promise<Hash>
}

export function clientsFor(provider: EthereumProvider): SubjectWalletClients {
  const walletClient = createWalletClient({chain: base, transport: custom(provider)})

  return {
    addresses: () => walletClient.getAddresses(),
    chainId: () => walletClient.getChainId(),
    switchToBase: async () => {
      await walletClient.switchChain({id: base.id})
    },
    send: request => walletClient.sendTransaction(request),
  }
}

/**
 * The one step of this operation the browser may hand to a wallet.
 *
 * The operation identity, the subject, the reviewed signer, the chain, the step
 * the server claimed and the exact bytes it reviewed all have to agree. A
 * terminal operation and an unknown step are refused rather than sent.
 */
export function sendableStep(
  operation: SubjectWalletOperation,
  actionId: string,
  stepName: string,
): SubjectStep {
  if (operation.action_id !== actionId) throw new Error("This is a different action.")
  if (operation.terminal) throw new Error("This action has already finished.")
  if (operation.chain_id !== base.id) throw new Error("This action is not for Base.")

  const step = operation.steps.find(candidate => candidate.step === stepName)
  if (!step) throw new Error("This step is not part of the reviewed action.")

  getAddress(step.to)
  if (!/^0x[0-9a-f]+$/.test(step.data)) throw new Error("The reviewed transaction changed.")

  return step
}

/**
 * Sends one reviewed step and returns its hash. Nothing is read afterwards: the
 * server owns every question about what that hash did.
 *
 * `onSendStarted` runs synchronously immediately before the wallet send, so a
 * caller can tell a failure that never asked the wallet for anything from one
 * that may already have put a transaction on Base.
 */
export async function sendSubjectStep(
  operation: SubjectWalletOperation,
  step: SubjectStep,
  source: EthereumProvider | (() => SelectedWallet | null),
  onSendStarted: () => void,
  suppliedClients?: SubjectWalletClients,
): Promise<Hash> {
  const selected = typeof source === "function" ? source() : null
  const provider = typeof source === "function" ? selected?.provider : source
  if (!provider) throw new Error("Wallet unavailable")
  const unchanged = () => {
    if (typeof source !== "function") return
    const current = source()
    if (!current || current.provider !== provider || getAddress(current.address) !== getAddress(operation.signer)) {
      throw new Error("The selected wallet changed")
    }
  }
  unchanged()
  const clients = suppliedClients ?? clientsFor(provider)
  let chainId = await clients.chainId()
  if (chainId !== base.id) {
    unchanged()
    await clients.switchToBase()
    chainId = await clients.chainId()
  }
  if (chainId !== base.id) throw new Error("Switch to Base before continuing.")

  // The account is read again here, immediately before the send, so a wallet
  // that moved after the server's own check still cannot be handed these bytes.
  const [account] = await clients.addresses()
  if (!account || getAddress(account) !== getAddress(operation.signer)) {
    throw new Error("Use the wallet this action was reviewed for.")
  }

  unchanged()
  if ((await clients.chainId()) !== base.id) throw new Error("Switch to Base before continuing.")
  unchanged()
  onSendStarted()
  return clients.send({account, to: getAddress(step.to), data: step.data, value: 0n})
}

/**
 * The exact EIP-1193 user-rejection code, walked out of whatever wrapper viem
 * put around it. Message text is never authority, so nothing else qualifies.
 */
export function userRejected(error: unknown): boolean {
  const seen = new Set<unknown>()
  let current: unknown = error

  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current)
    if ((current as {code?: unknown}).code === 4001) return true
    current = (current as {cause?: unknown}).cause
  }

  return false
}
