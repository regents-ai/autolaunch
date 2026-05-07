import { base, baseSepolia, mainnet } from "viem/chains"

export function walletActionNetworkLabel(chainId: number): string {
  if (chainId === base.id) return "Base mainnet"
  if (chainId === baseSepolia.id) return "the Base Sepolia network"
  if (chainId === mainnet.id) return "Ethereum mainnet"
  throw new Error("This wallet action is not available for the selected network.")
}

export function walletActionNetworkSwitchMessage(chainId: number): string {
  return `Switch your wallet to ${walletActionNetworkLabel(chainId)} before continuing.`
}
