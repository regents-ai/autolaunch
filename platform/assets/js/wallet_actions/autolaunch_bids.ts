import {createWalletClient, custom, getAddress, type Address, type Hash, type Hex} from "viem"
import {base} from "viem/chains"

import type {EthereumProvider} from "./connected_wallet"
import {
  labNetwork,
  sendLabTransaction,
  type AutolaunchLabBinding,
  type AutolaunchLabAnchor,
  type WalletResolver,
} from "./autolaunch_network"

export type BidStepName = "token_approval" | "permit2_approval" | "bid" | "usdc_approval" | "usdc_bid"

export type BidStep = {
  step: BidStepName
  to: Address
  data: Hex
}

/**
 * The reviewed sequence exactly as the server wrote it. The browser holds it so
 * it can check that what it is asked to send really belongs to this operation,
 * and never so it can build a transaction of its own: there is no encoder here.
 */
export type BidOperation = {
  action_id: string
  signer: Address
  chain_id: number
  lab: AutolaunchLabBinding | null
  lab_anchor: AutolaunchLabAnchor | null
  terminal: boolean
  steps: BidStep[]
}

export type BidClients = {
  addresses(): Promise<Address[]>
  chainId(): Promise<number>
  switchToBase(): Promise<void>
  send(request: {account: Address; to: Address; data: Hex; value: bigint}): Promise<Hash>
}

export function clientsFor(provider: EthereumProvider): BidClients {
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
 * The operation identity, the reviewed signer, the chain, the step the server
 * claimed and the exact bytes it reviewed all have to agree. A terminal
 * operation and an unknown step are refused rather than sent.
 */
export function sendableStep(
  operation: BidOperation,
  actionId: string,
  stepName: string,
): BidStep {
  if (operation.action_id !== actionId) throw new Error("This is a different bid.")
  if (operation.terminal) throw new Error("This bid has already finished.")
  if (operation.lab === null && operation.chain_id !== base.id) {
    throw new Error("This bid is not for Base.")
  }
  labNetwork(operation)

  const step = operation.steps.find(candidate => candidate.step === stepName)
  if (!step) throw new Error("This step is not part of the reviewed bid.")

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
export async function sendBidStep(
  operation: BidOperation,
  step: BidStep,
  resolveWallet: WalletResolver,
  onSendStarted: () => void,
  clientFactory: (provider: EthereumProvider) => BidClients = clientsFor,
): Promise<Hash> {
  if (labNetwork(operation)) {
    return sendLabTransaction(operation, step, resolveWallet, onSendStarted)
  }

  const selected = selectedWallet(resolveWallet, operation.signer)
  const clients = clientFactory(selected.provider)

  if ((await clients.chainId()) !== base.id) {
    sameSelectedWallet(resolveWallet, selected.provider, operation.signer)
    await clients.switchToBase()
  }

  sameSelectedWallet(resolveWallet, selected.provider, operation.signer)

  const [account] = await clients.addresses()
  if (!account || getAddress(account) !== getAddress(operation.signer)) {
    throw new Error("Use the wallet this bid was reviewed for.")
  }

  sameSelectedWallet(resolveWallet, selected.provider, operation.signer)

  if ((await clients.chainId()) !== base.id) {
    throw new Error("Switch to Base before continuing.")
  }

  sameSelectedWallet(resolveWallet, selected.provider, operation.signer)

  onSendStarted()
  return clients.send({account, to: getAddress(step.to), data: step.data, value: 0n})
}

function selectedWallet(resolveWallet: WalletResolver, signer: Address) {
  const selected = resolveWallet()
  if (!selected || getAddress(selected.address) !== getAddress(signer)) {
    throw new Error("Use the wallet this bid was reviewed for.")
  }
  return selected
}

function sameSelectedWallet(
  resolveWallet: WalletResolver,
  provider: EthereumProvider,
  signer: Address,
): void {
  const current = resolveWallet()
  if (
    !current ||
    current.provider !== provider ||
    getAddress(current.address) !== getAddress(signer)
  ) {
    throw new Error("The selected wallet changed. Review this bid again.")
  }
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
