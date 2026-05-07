import { useActiveWallet, usePrivy, useWallets } from "@privy-io/react-auth"
import React from "react"
import { createWalletClient, custom, isAddress, type WalletClient } from "viem"
import { base, baseSepolia, mainnet } from "viem/chains"

export interface PrivyUserWalletAccountLike {
  type?: string
  address?: `0x${string}`
}

export interface PrivyUserLike {
  id?: string
  wallet?: { address?: `0x${string}` }
  linkedAccounts?: PrivyUserWalletAccountLike[]
}

export interface PrivyEthereumWalletLike {
  type: "ethereum"
  address: `0x${string}`
  chainId?: string | number | null
  walletClientType?: string | null
  getEthereumProvider: () => Promise<unknown>
}

interface PrivyWalletLike {
  type?: string
  address?: `0x${string}`
  chainId?: string | number | null
  walletClientType?: string | null
  getEthereumProvider?: () => Promise<unknown>
}

type AccountsChangedListener = (accounts: unknown) => void

type WalletProviderAccountEvents = {
  on?: (event: "accountsChanged", listener: AccountsChangedListener) => void
  off?: (event: "accountsChanged", listener: AccountsChangedListener) => void
  removeListener?: (event: "accountsChanged", listener: AccountsChangedListener) => void
}

type UsePrivyWalletClientOptions = {
  onAccountChanged?: (account: `0x${string}` | null) => void
}

export function resolvePrivyChainId(chainId: string | number | null | undefined): number | null {
  if (typeof chainId === "number") return chainId

  if (typeof chainId === "string") {
    const numeric = chainId.includes(":") ? chainId.split(":").pop() : chainId
    const parsed = numeric ? Number.parseInt(numeric, 10) : Number.NaN
    return Number.isFinite(parsed) ? parsed : null
  }

  return null
}

function normalizeWalletAddress(value: string | null | undefined): `0x${string}` | null {
  const trimmed = value?.trim()
  if (!trimmed || !isAddress(trimmed, { strict: false })) return null
  return trimmed as `0x${string}`
}

export function accountFromAccountsChanged(accounts: unknown): `0x${string}` | null {
  if (!Array.isArray(accounts)) return null
  const [account] = accounts
  return normalizeWalletAddress(typeof account === "string" ? account : null)
}

export function bindWalletProviderAccountChange(
  provider: unknown,
  onAccountChanged: (account: `0x${string}` | null) => void,
): () => void {
  const accountEvents = provider as WalletProviderAccountEvents | null | undefined

  if (!accountEvents || typeof accountEvents.on !== "function") return () => {}

  const listener = (accounts: unknown) => {
    onAccountChanged(accountFromAccountsChanged(accounts))
  }

  accountEvents.on("accountsChanged", listener)

  return () => {
    if (typeof accountEvents.removeListener === "function") {
      accountEvents.removeListener("accountsChanged", listener)
      return
    }

    if (typeof accountEvents.off === "function") {
      accountEvents.off("accountsChanged", listener)
    }
  }
}

export function getWalletAddressFromPrivyUser(privyUser: unknown): `0x${string}` | null {
  const user = privyUser as PrivyUserLike | null | undefined

  if (!user) return null
  if (user.wallet?.address) return user.wallet.address

  const linkedAccounts = Array.isArray(user.linkedAccounts) ? user.linkedAccounts : []
  const walletAccount = linkedAccounts.find((account) =>
    account.type === "wallet" || account.type === "wallet_account" || account.type === "ethereum"
  )

  return walletAccount?.address ?? null
}

export function getPrivyIdFromUser(privyUser: unknown): string | null {
  const user = privyUser as Pick<PrivyUserLike, "id"> | null | undefined
  if (typeof user?.id !== "string") return null

  const trimmed = user.id.trim()
  return trimmed.length > 0 ? trimmed : null
}

export function isPrivyEthereumWallet(value: unknown): value is PrivyEthereumWalletLike {
  const wallet = value as PrivyWalletLike | null | undefined

  return (
    wallet?.type === "ethereum" &&
    typeof wallet.address === "string" &&
    typeof wallet.getEthereumProvider === "function"
  )
}

function isEmbeddedPrivyWallet(wallet: PrivyEthereumWalletLike): boolean {
  return wallet.walletClientType === "privy"
}

function matchesPrivyUserAddress(
  wallet: PrivyEthereumWalletLike,
  privyUserAddress: `0x${string}` | null,
): boolean {
  return (
    typeof privyUserAddress === "string" &&
    wallet.address.toLowerCase() === privyUserAddress.toLowerCase()
  )
}

export function selectPrivyEthereumWallet(args: {
  activeWallet: unknown
  wallets: readonly unknown[] | null | undefined
  privyUserAddress: `0x${string}` | null
}): PrivyEthereumWalletLike | null {
  if (
    isPrivyEthereumWallet(args.activeWallet) &&
    (isEmbeddedPrivyWallet(args.activeWallet) ||
      matchesPrivyUserAddress(args.activeWallet, args.privyUserAddress))
  ) {
    return args.activeWallet
  }

  const ethereumWallets = (args.wallets ?? []).filter(isPrivyEthereumWallet)

  const embeddedMatchingWallet =
    ethereumWallets.find(
      (wallet) =>
        isEmbeddedPrivyWallet(wallet) &&
        matchesPrivyUserAddress(wallet, args.privyUserAddress),
    ) ?? null

  if (embeddedMatchingWallet) return embeddedMatchingWallet

  const matchingWallet =
    ethereumWallets.find((wallet) =>
      matchesPrivyUserAddress(wallet, args.privyUserAddress),
    ) ?? null

  if (matchingWallet) return matchingWallet

  return ethereumWallets.find(isEmbeddedPrivyWallet) ?? null
}

export function getLinkedWalletAddressesFromPrivyUser(privyUser: unknown): `0x${string}`[] {
  const user = privyUser as PrivyUserLike | null | undefined

  if (!user) return []

  const candidateAddresses = new Set<`0x${string}`>()

  if (user.wallet?.address) candidateAddresses.add(user.wallet.address)

  const linkedAccounts = Array.isArray(user.linkedAccounts) ? user.linkedAccounts : []

  linkedAccounts.forEach((account) => {
    if (
      (account.type === "wallet" ||
        account.type === "wallet_account" ||
        account.type === "ethereum") &&
      typeof account.address === "string"
    ) {
      candidateAddresses.add(account.address)
    }
  })

  return Array.from(candidateAddresses)
}

export function formatPrivySessionErrorMessage(error: unknown): string {
  const message =
    error instanceof Error && typeof error.message === "string" ? error.message.trim() : ""

  const status =
    typeof error === "object" &&
    error !== null &&
    "status" in error &&
    typeof error.status === "number"
      ? error.status
      : null

  if (status === 429 || /too many requests/i.test(message)) {
    return "Too many sign-in attempts just now. Wait a few seconds, then try again."
  }

  if (
    message === "" ||
    status === 401 ||
    /privy identity token/i.test(message) ||
    /linked wallet required/i.test(message) ||
    /wallet session is not ready/i.test(message)
  ) {
    return "Could not finish sign in. Wait a few seconds, then try again."
  }

  return message
}

export interface UsePrivyWalletClientResult {
  account: `0x${string}` | null
  privyId: string | null
  wallet: PrivyEthereumWalletLike | null
  walletClient: WalletClient | null
  chainId: number | null
}

export function usePrivyWalletClient(
  options: UsePrivyWalletClientOptions = {},
): UsePrivyWalletClientResult {
  const { user: privyUser } = usePrivy()
  const { wallet: activeWallet } = useActiveWallet()
  const { wallets } = useWallets()

  const privyUserAddress = React.useMemo(
    () => getWalletAddressFromPrivyUser(privyUser),
    [privyUser],
  )
  const privyId = React.useMemo(() => getPrivyIdFromUser(privyUser), [privyUser])
  const wallet = React.useMemo(
    () =>
      selectPrivyEthereumWallet({
        activeWallet,
        wallets,
        privyUserAddress,
      }),
    [activeWallet, privyUserAddress, wallets],
  )
  const account = (wallet?.address ?? privyUserAddress ?? null) as `0x${string}` | null
  const chainId = React.useMemo(() => resolvePrivyChainId(wallet?.chainId ?? null), [wallet?.chainId])
  const [walletClient, setWalletClient] = React.useState<WalletClient | null>(null)
  const onAccountChanged = options.onAccountChanged

  React.useEffect(() => {
    let cancelled = false
    let cleanupAccountChange: (() => void) | null = null

    if (!wallet) {
      setWalletClient(null)
      return
    }

    void (async () => {
      try {
        const provider = await wallet.getEthereumProvider()
        if (cancelled) return

        if (onAccountChanged) {
          cleanupAccountChange = bindWalletProviderAccountChange(provider, onAccountChanged)
        }

        const resolvedChainId = resolvePrivyChainId(wallet.chainId) ?? base.id
        const chain =
          resolvedChainId === mainnet.id
            ? mainnet
            : resolvedChainId === baseSepolia.id
              ? baseSepolia
              : base

        setWalletClient(
          createWalletClient({
            account: wallet.address,
            chain,
            transport: custom(provider as any),
          }),
        )
      } catch {
        if (!cancelled) setWalletClient(null)
      }
    })()

    return () => {
      cancelled = true
      cleanupAccountChange?.()
    }
  }, [onAccountChanged, wallet, wallet?.address, wallet?.chainId])

  return { account, privyId, wallet, walletClient, chainId }
}
