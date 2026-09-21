import {getAddress, type Address, type Hash, type Hex} from "viem"

import {
  labNetwork,
  sendLabTransaction,
  type AutolaunchLabBinding,
  type AutolaunchLabAnchor,
  type WalletResolver,
} from "./autolaunch_network"

export type LaunchStepName = "launch"

export type LaunchStep = {
  step: LaunchStepName
  to: Address
  data: Hex
}

/**
 * The reviewed sequence exactly as the server wrote it. The browser holds it so
 * it can check that what it is asked to send really belongs to this operation,
 * and never so it can build a transaction of its own: there is no encoder here.
 */
export type LaunchOperation = {
  action_id: string
  signer: Address
  chain_id: number
  lab: AutolaunchLabBinding
  lab_anchor: AutolaunchLabAnchor
  terminal: boolean
  steps: LaunchStep[]
}

/**
 * The one step of this launch the browser may hand to a wallet.
 *
 * The operation identity, the reviewed signer, the network binding, the step
 * the server claimed and the exact bytes it reviewed all have to agree. A
 * terminal operation and an unknown step are refused rather than sent.
 */
export function sendableStep(
  operation: LaunchOperation,
  actionId: string,
  stepName: string,
): LaunchStep {
  if (operation.action_id !== actionId) throw new Error("This is a different launch.")
  if (operation.terminal) throw new Error("This launch has already finished.")
  labNetwork(operation)

  const step = operation.steps.find(candidate => candidate.step === stepName)
  if (!step) throw new Error("This step is not part of the reviewed launch.")

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
 * that may already have put a transaction on the chain.
 */
export function sendLaunchStep(
  operation: LaunchOperation,
  step: LaunchStep,
  resolveWallet: WalletResolver,
  onSendStarted: () => void,
): Promise<Hash> {
  return sendLabTransaction(operation, step, resolveWallet, onSendStarted)
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
