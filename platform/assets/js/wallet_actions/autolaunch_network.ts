import {getAddress, type Address, type Hash, type Hex} from "viem"

import type {EthereumProvider, SelectedWallet} from "./connected_wallet"

// The Base fork lab and the blank Robinhood lab carry test assets; a lab may
// be reset between a review and a press, so a send on one is anchored to the
// reviewed block.
const testChainIds: readonly number[] = [31_337, 31_338]

/**
 * The deployment description's binding every reviewed action carries: the
 * deployment label, the RPC door wallets use, the chain and the addresses the
 * review depends on.
 */
export type AutolaunchLabBinding = {
  run_id: string
  rpc_url: string
  chain_id: number
  addresses: Record<string, string>
}

export type AutolaunchNetworkOperation = {
  chain_id: number
  lab: AutolaunchLabBinding
  lab_anchor: AutolaunchLabAnchor
}

export type AutolaunchLabAnchor = {
  block_number: number
  block_hash: Hash
}

export type AutolaunchTransaction = {
  to: Address
  data: Hex
}

/**
 * The wallet answered, but for another network: its copy of this chain id
 * points somewhere other than the chain the action was reviewed on. Nothing
 * was sent, and only the wallet's own network settings can fix it.
 */
export class LabNetworkMismatch extends Error {}

type LabNetwork = {chainId: number; rpcUrl: string; chainName: string; testChain: boolean}
export type WalletResolver = () => SelectedWallet | null

export function labNetwork(operation: AutolaunchNetworkOperation): LabNetwork {
  const binding = operation.lab
  if (
    !plainObject(binding) ||
    Object.keys(binding).sort().join(",") !== "addresses,chain_id,rpc_url,run_id" ||
    typeof binding.run_id !== "string" ||
    binding.run_id.trim() === "" ||
    !Number.isSafeInteger(operation.chain_id) ||
    operation.chain_id <= 0 ||
    binding.chain_id !== operation.chain_id ||
    !labAddresses(binding.addresses)
  ) {
    throw new Error("The network binding changed.")
  }

  const chainName = labChainName(operation.chain_id, binding.rpc_url)
  if (chainName === null) throw new Error("The network binding changed.")

  return {
    chainId: operation.chain_id,
    rpcUrl: binding.rpc_url,
    chainName,
    testChain: testChainIds.includes(operation.chain_id),
  }
}

/**
 * Sends one server-reviewed transaction through the selected wallet. Account
 * and chain are read again for every call. The final provider request before
 * the send is always `eth_chainId`, so a wallet that switches networks during
 * setup is refused before it sees the transaction.
 */
export async function sendLabTransaction(
  operation: AutolaunchNetworkOperation & {signer: Address},
  transaction: AutolaunchTransaction,
  resolveWallet: WalletResolver,
  onSendStarted: () => void,
): Promise<Hash> {
  const network = labNetwork(operation)
  const anchor = labAnchor(operation)
  const selected = selectedWallet(resolveWallet, operation.signer)
  const provider = selected.provider

  if ((await providerChainId(provider)) !== network.chainId) {
    await switchToLab(provider, network)
  }

  sameSelectedWallet(resolveWallet, selected, operation.signer)

  if (network.testChain && !(await anchoredToLab(provider, anchor))) {
    await refreshLab(provider, network)
    sameSelectedWallet(resolveWallet, selected, operation.signer)

    if (
      (await providerChainId(provider)) !== network.chainId ||
      !(await anchoredToLab(provider, anchor))
    ) {
      throw new LabNetworkMismatch("The selected wallet is connected to a different fork.")
    }
  }

  sameSelectedWallet(resolveWallet, selected, operation.signer)

  const accounts = await provider.request({method: "eth_accounts"})
  const [account] = Array.isArray(accounts) ? accounts : []
  if (
    typeof account !== "string" ||
    getAddress(account) !== getAddress(operation.signer)
  ) {
    throw new Error("Use the wallet this action was reviewed for.")
  }

  sameSelectedWallet(resolveWallet, selected, operation.signer)

  if ((await providerChainId(provider)) !== network.chainId) {
    throw new LabNetworkMismatch(`Switch to ${network.chainName} before continuing.`)
  }

  // This synchronous check cannot open a provider request, so `eth_chainId`
  // remains the final asynchronous read before reviewed calldata reaches the
  // wallet. It catches Privy changing the selected wallet during that read.
  sameSelectedWallet(resolveWallet, selected, operation.signer)

  onSendStarted()
  const result = await provider.request({
    method: "eth_sendTransaction",
    params: [
      {
        from: getAddress(account),
        to: getAddress(transaction.to),
        data: transaction.data,
        value: "0x0",
      },
    ],
  })

  if (typeof result !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(result)) {
    throw new Error("The wallet did not return a transaction hash.")
  }
  return result as Hash
}

function labAnchor(operation: AutolaunchNetworkOperation): AutolaunchLabAnchor {
  const anchor = operation.lab_anchor
  if (
    !plainObject(anchor) ||
    Object.keys(anchor).sort().join(",") !== "block_hash,block_number" ||
    !Number.isSafeInteger(anchor.block_number) ||
    anchor.block_number < 0 ||
    typeof anchor.block_hash !== "string" ||
    !/^0x[0-9a-f]{64}$/.test(anchor.block_hash)
  ) {
    throw new Error("The review anchor changed.")
  }

  return anchor as AutolaunchLabAnchor
}

function selectedWallet(resolveWallet: WalletResolver, signer: Address): SelectedWallet {
  const selected = resolveWallet()
  if (!selected || !sameAddress(selected.address, signer)) {
    throw new Error("Use the wallet this action was reviewed for.")
  }
  return selected
}

function sameSelectedWallet(
  resolveWallet: WalletResolver,
  selected: SelectedWallet,
  signer: Address,
): void {
  const current = resolveWallet()
  if (
    !current ||
    current.provider !== selected.provider ||
    !sameAddress(current.address, signer) ||
    !sameAddress(current.address, selected.address)
  ) {
    throw new Error("The selected wallet changed. Review this action again.")
  }
}

async function anchoredToLab(
  provider: EthereumProvider,
  anchor: AutolaunchLabAnchor,
): Promise<boolean> {
  // A wallet whose network cannot answer for the reviewed block is not on the fork.
  try {
    const block = await provider.request({
      method: "eth_getBlockByNumber",
      params: [`0x${anchor.block_number.toString(16)}`, false],
    })

    return plainObject(block) && sameHex(block.hash, anchor.block_hash)
  } catch {
    return false
  }
}

async function switchToLab(provider: EthereumProvider, network: LabNetwork): Promise<void> {
  const chainId = `0x${network.chainId.toString(16)}`

  try {
    await provider.request({method: "wallet_switchEthereumChain", params: [{chainId}]})
  } catch (error) {
    if (!hasCode(error, 4902)) throw error

    await addLabChain(provider, network)
    await provider.request({method: "wallet_switchEthereumChain", params: [{chainId}]})
  }
}

async function refreshLab(provider: EthereumProvider, network: LabNetwork): Promise<void> {
  try {
    await addLabChain(provider, network)
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{chainId: `0x${network.chainId.toString(16)}`}],
    })
  } catch {
    throw new LabNetworkMismatch("The selected wallet could not connect to the current fork.")
  }
}

function addLabChain(provider: EthereumProvider, network: LabNetwork): Promise<unknown> {
  return provider.request({
    method: "wallet_addEthereumChain",
    params: [
      {
        chainId: `0x${network.chainId.toString(16)}`,
        chainName: network.chainName,
        nativeCurrency: {
          name: network.testChain ? "Test Ether" : "Ether",
          symbol: "ETH",
          decimals: 18,
        },
        rpcUrls: [network.rpcUrl],
      },
    ],
  })
}

async function providerChainId(provider: EthereumProvider): Promise<number> {
  const value = await provider.request({method: "eth_chainId"})
  if (typeof value !== "string" || !/^0x[0-9a-f]+$/i.test(value)) return -1

  const parsed = Number(BigInt(value))
  return Number.isSafeInteger(parsed) ? parsed : -1
}

/**
 * The chain name the wallet prompt shows for a reviewed chain and its
 * wallet-facing RPC door. Base is reached through an `https://` door without
 * credentials, query or fragment. A loopback `http://127.0.0.1:PORT` is a
 * local lab; an `https://` door on the Base fork chain is a hosted preview.
 * Any other `http://` URL is refused: the site's own private door never
 * reaches a wallet. The Robinhood lab only ever runs locally.
 */
function labChainName(chainId: number, value: unknown): string | null {
  if (typeof value !== "string") return null
  if (chainId === 8453) return publicHttpsRpc(value) ? "Base" : null
  if (chainId === 31_338) return literalLoopbackRpc(value) ? "Robinhood Local Lab" : null
  if (chainId !== 31_337) return null
  if (literalLoopbackRpc(value)) return "Autolaunch Local Lab"
  if (publicHttpsRpc(value)) return "Autolaunch preview (Base fork)"
  return null
}

function literalLoopbackRpc(value: string): boolean {
  const match = /^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})$/.exec(value)
  if (!match) return false

  const port = Number(match[1])
  return port <= 65_535 && String(port) === match[1]
}

function publicHttpsRpc(value: string): boolean {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    return false
  }

  return (
    url.protocol === "https:" &&
    url.hostname !== "" &&
    url.username === "" &&
    url.password === "" &&
    url.search === "" &&
    url.hash === "" &&
    !value.endsWith("?") &&
    !value.endsWith("#")
  )
}

function labAddresses(value: unknown): value is Record<string, string> {
  if (!plainObject(value)) return false
  const entries = Object.entries(value)
  return (
    entries.length > 0 &&
    entries.every(
      ([key, address]) => key.length > 0 && /^0x[0-9a-f]{40}$/.test(String(address)),
    )
  )
}

function plainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function sameAddress(left: string, right: string): boolean {
  try {
    return getAddress(left) === getAddress(right)
  } catch {
    return false
  }
}

function sameHex(left: unknown, right: string): boolean {
  return typeof left === "string" && left.toLowerCase() === right.toLowerCase()
}

function hasCode(error: unknown, code: number): boolean {
  const seen = new Set<unknown>()
  let current = error

  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current)
    if ((current as {code?: unknown}).code === code) return true
    current = (current as {cause?: unknown}).cause
  }
  return false
}
