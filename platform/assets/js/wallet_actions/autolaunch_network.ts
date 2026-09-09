import {getAddress, type Address, type Hash, type Hex} from "viem"

import type {EthereumProvider, SelectedWallet} from "./connected_wallet"

export const autolaunchLabChainId = 31_337

export type AutolaunchLabBinding = {
  run_id: string
  rpc_url: string
  chain_id: number
  addresses: Record<string, string>
}

export type AutolaunchNetworkOperation = {
  chain_id: number
  lab: AutolaunchLabBinding | null
  lab_anchor: AutolaunchLabAnchor | null
}

export type AutolaunchLabAnchor = {
  block_number: number
  block_hash: Hash
}

export type AutolaunchTransaction = {
  to: Address
  data: Hex
}

type LabNetwork = {chainId: typeof autolaunchLabChainId; rpcUrl: string; chainName: string}
export type WalletResolver = () => SelectedWallet | null

export function labNetwork(operation: AutolaunchNetworkOperation): LabNetwork | null {
  if (operation.lab === null) {
    if (operation.chain_id !== 8453) throw new Error("This action is not for Base.")
    return null
  }

  if (operation.chain_id !== autolaunchLabChainId) {
    throw new Error("A fork action cannot use Base.")
  }

  const binding = operation.lab
  if (
    !plainObject(binding) ||
    Object.keys(binding).sort().join(",") !== "addresses,chain_id,rpc_url,run_id" ||
    typeof binding.run_id !== "string" ||
    binding.run_id.trim() === "" ||
    binding.chain_id !== autolaunchLabChainId ||
    !labAddresses(binding.addresses)
  ) {
    throw new Error("The fork network binding changed.")
  }

  const chainName = labChainName(binding.rpc_url)
  if (chainName === null) throw new Error("The fork network binding changed.")

  return {chainId: autolaunchLabChainId, rpcUrl: binding.rpc_url, chainName}
}

/**
 * Sends one server-reviewed fork transaction through the selected wallet.
 * Account and chain are read again for every call. The final provider request
 * before the send is always `eth_chainId`, so a wallet that switches back to
 * Base during setup is refused before it sees the transaction.
 */
export async function sendLabTransaction(
  operation: AutolaunchNetworkOperation & {signer: Address},
  transaction: AutolaunchTransaction,
  resolveWallet: WalletResolver,
  onSendStarted: () => void,
): Promise<Hash> {
  const network = labNetwork(operation)
  if (!network) throw new Error("This is not a fork action.")
  const anchor = labAnchor(operation)
  const selected = selectedWallet(resolveWallet, operation.signer)
  const provider = selected.provider

  if ((await providerChainId(provider)) !== network.chainId) {
    await switchToLab(provider, network)
  }

  sameSelectedWallet(resolveWallet, selected, operation.signer)

  if (!(await anchoredToLab(provider, anchor))) {
    await refreshLab(provider, network)
    sameSelectedWallet(resolveWallet, selected, operation.signer)

    if (
      (await providerChainId(provider)) !== network.chainId ||
      !(await anchoredToLab(provider, anchor))
    ) {
      throw new Error("The selected wallet is connected to a different fork.")
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
    throw new Error("Switch to the Autolaunch fork before continuing.")
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
    throw new Error("The fork review anchor changed.")
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
  const block = await provider.request({
    method: "eth_getBlockByNumber",
    params: [`0x${anchor.block_number.toString(16)}`, false],
  })

  return plainObject(block) && sameHex(block.hash, anchor.block_hash)
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
    throw new Error("The selected wallet could not connect to the current fork.")
  }
}

function addLabChain(provider: EthereumProvider, network: LabNetwork): Promise<unknown> {
  return provider.request({
    method: "wallet_addEthereumChain",
    params: [
      {
        chainId: `0x${network.chainId.toString(16)}`,
        chainName: network.chainName,
        nativeCurrency: {name: "Test Ether", symbol: "ETH", decimals: 18},
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
 * The wallet-facing RPC door and the chain name the wallet prompt shows for
 * it. A loopback `http://127.0.0.1:PORT` is the local lab; an `https://` URL
 * without credentials, query or fragment is a hosted fork preview. Any other
 * `http://` URL is refused: the site's own private door never reaches a wallet.
 */
function labChainName(value: unknown): string | null {
  if (typeof value !== "string") return null
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
