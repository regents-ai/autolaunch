import { createPublicClient, http } from "viem"
import { base, baseSepolia, mainnet } from "viem/chains"

import { assertPreparedSigner } from "./wallet-bridge-prepared-signer"
import { walletActionNetworkSwitchMessage } from "./wallet-bridge-network"
import { ensureWalletReady } from "./wallet-bridge-runtime"

type WalletTxRequest = {
  chain_id: number
  to: `0x${string}`
  value?: string | null
  data?: `0x${string}` | null
  expected_signer?: `0x${string}` | null
}

type WalletTxOptions = {
  baseRpcUrl?: string | null
  baseSepoliaRpcUrl?: string | null
  failureMessage?: string | null
}

function chainForTransaction(chainId: number) {
  if (chainId === base.id) return base
  if (chainId === baseSepolia.id) return baseSepolia
  if (chainId === mainnet.id) return mainnet
  throw new Error("This wallet action is not available for the selected network.")
}

function rpcUrlForTransaction(chainId: number, options: WalletTxOptions) {
  if (chainId === base.id) return options.baseRpcUrl ?? undefined
  if (chainId === baseSepolia.id) return options.baseSepoliaRpcUrl ?? undefined
  return undefined
}

export async function sendWalletBridgeTransaction(
  txRequest: WalletTxRequest,
  options: WalletTxOptions = {},
): Promise<`0x${string}`> {
  const wallet = ensureWalletReady()

  if (wallet.chainId !== txRequest.chain_id) {
    throw new Error(walletActionNetworkSwitchMessage(txRequest.chain_id))
  }

  assertPreparedSigner(wallet.account, txRequest.expected_signer)

  const chain = chainForTransaction(txRequest.chain_id)
  const value =
    typeof txRequest.value === "string" && txRequest.value.trim() !== ""
      ? BigInt(txRequest.value)
      : 0n

  const hash = await wallet.walletClient.sendTransaction({
    account: wallet.account,
    chain,
    to: txRequest.to,
    data: txRequest.data ?? undefined,
    value,
  })

  const client = createPublicClient({
    chain,
    transport: http(rpcUrlForTransaction(chain.id, options)),
  })

  const receipt = await client.waitForTransactionReceipt({
    hash,
    timeout: 120_000,
  })

  if (receipt.status !== "success") {
    throw new Error(options.failureMessage ?? "The transaction did not finish successfully.")
  }

  return hash
}
