type StakingWalletSessionState = {
  authenticated: boolean
  account: string | null
  walletClient: unknown
}

function normalizeWalletAddress(value: string | null | undefined): string | null {
  const trimmed = value?.trim()

  if (!trimmed) return null
  if (!/^0x[0-9a-fA-F]{40}$/.test(trimmed)) return null

  return trimmed.toLowerCase()
}

export function stakingActionNeedsWalletConfirmation(
  walletState: StakingWalletSessionState,
): boolean {
  const account = normalizeWalletAddress(walletState.account)

  if (!walletState.authenticated || !account) return true
  if (!walletState.walletClient) return true

  return false
}
