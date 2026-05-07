import { getIdentityToken } from "@privy-io/react-auth"
import { base } from "viem/chains"

import { emptyWalletBridgeState, type WalletBridgeState } from "./wallet-bridge-state"
import {
  debugHttpError,
  fetchJson,
  privyDebugLog,
  redactWalletForDebug,
} from "./wallet-bridge-shared"

let walletBridgeState: WalletBridgeState = emptyWalletBridgeState()
let walletSessionSyncInFlight: Promise<PrivySessionResponse> | null = null

export const WALLET_STATE_EVENT = "autolaunch:wallet-state"
export const WALLET_SIGNATURE_REQUEST_EVENT = "autolaunch:wallet-signature-requested"
export const WALLET_EXTENSION_ACCOUNT_CHANGED_EVENT =
  "autolaunch:wallet-extension-account-changed"

type XmtpReadyState = {
  status: "ready"
  inbox_id: string
  wallet_address: string
}

type XmtpSignatureRequiredState = {
  status: "signature_required"
  inbox_id: null
  wallet_address: string
  client_id: string
  signature_request_id: string
  signature_text: string
}

type PrivySessionResponse = {
  ok: boolean
  human?: {
    wallet_address?: string | null
  } | null
  xmtp?: XmtpReadyState | XmtpSignatureRequiredState | null
}

export function getWalletBridgeState(): WalletBridgeState {
  return walletBridgeState
}

export function setWalletBridgeState(state: WalletBridgeState): void {
  walletBridgeState = state
}

export function resetWalletBridgeState(): void {
  walletBridgeState = emptyWalletBridgeState()
}

export function createWalletBridgeDispatchKey(state: WalletBridgeState): string {
  return JSON.stringify({
    privyReady: state.privyReady,
    authenticated: state.authenticated,
    isModalOpen: state.isModalOpen,
    account: state.account,
    chainId: state.chainId,
    privyId: state.privyId,
    identityToken: state.identityToken ?? "",
    linkedWalletAddresses: [...state.linkedWalletAddresses].sort(),
  })
}

export function emitWalletBridgeState() {
  window.dispatchEvent(
    new CustomEvent(WALLET_STATE_EVENT, {
      detail: {
        privyReady: walletBridgeState.privyReady,
        authenticated: walletBridgeState.authenticated,
        isModalOpen: walletBridgeState.isModalOpen,
        account: walletBridgeState.account,
        chainId: walletBridgeState.chainId,
      },
    }),
  )
}

export function emitWalletExtensionAccountChanged(account: `0x${string}` | null): void {
  window.dispatchEvent(
    new CustomEvent(WALLET_EXTENSION_ACCOUNT_CHANGED_EVENT, {
      detail: { account },
    }),
  )
}

export function requestWalletSignature(): void {
  window.dispatchEvent(new CustomEvent(WALLET_SIGNATURE_REQUEST_EVENT))
}

export function walletReadyForBridgeSession(): boolean {
  return (
    walletBridgeState.authenticated &&
    walletBridgeState.account !== null &&
    walletBridgeState.linkedWalletAddresses.some(
      (candidate) => candidate.toLowerCase() === walletBridgeState.account?.toLowerCase(),
    )
  )
}

export function syncPrivySessionOnce(endpoint: string): Promise<PrivySessionResponse> {
  if (!walletSessionSyncInFlight) {
    walletSessionSyncInFlight = syncPrivySession(endpoint).finally(() => {
      walletSessionSyncInFlight = null
    })
  }

  return walletSessionSyncInFlight
}

export async function clearPrivySession(endpoint: string) {
  await fetchJson(endpoint, { method: "DELETE" })
}

export function ensureWalletReady() {
  if (
    !walletBridgeState.authenticated ||
    !walletBridgeState.account ||
    !walletBridgeState.walletClient
  ) {
    throw new Error("Sign in with your wallet first.")
  }

  return {
    account: walletBridgeState.account,
    chainId: walletBridgeState.chainId ?? base.id,
    walletClient: walletBridgeState.walletClient,
  }
}

async function syncPrivySession(endpoint: string): Promise<PrivySessionResponse> {
  privyDebugLog("info", "sync-privy-session:start", {
    endpoint,
    authenticated: walletBridgeState.authenticated,
    account: redactWalletForDebug(walletBridgeState.account),
    linkedWalletAddresses: walletBridgeState.linkedWalletAddresses.map(redactWalletForDebug),
    readyForBridgeSession: walletReadyForBridgeSession(),
    hasCachedIdentityToken: Boolean(walletBridgeState.identityToken),
  })

  if (!walletBridgeState.account || !walletReadyForBridgeSession()) {
    throw new Error("Wallet session is not ready.")
  }

  let identityToken = await resolveIdentityToken()
  if (!identityToken) {
    identityToken = await refreshIdentityToken()
  }

  if (!identityToken) {
    throw new Error("Wallet session is not ready.")
  }

  try {
    const session = await postPrivySession(endpoint, identityToken)
    await completeXmtpIdentity(endpoint, session)

    privyDebugLog("info", "sync-privy-session:success", {
      endpoint,
      account: redactWalletForDebug(walletBridgeState.account),
      xmtpStatus: session.xmtp?.status ?? null,
    })

    return session
  } catch (error) {
    privyDebugLog("error", "sync-privy-session:failed", {
      endpoint,
      account: redactWalletForDebug(walletBridgeState.account),
      ...debugHttpError(error),
    })
    throw error
  }
}

async function postPrivySession(
  endpoint: string,
  identityToken: string,
): Promise<PrivySessionResponse> {
  const walletAddresses = walletAddressesForSession()

  return fetchJson<PrivySessionResponse>(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${identityToken}`,
    },
    body: JSON.stringify({
      display_name: walletBridgeState.displayName,
      wallet_address: walletBridgeState.account,
      wallet_addresses: walletAddresses,
    }),
  })
}

function walletAddressesForSession(): `0x${string}`[] {
  const addresses = new Set<`0x${string}`>()
  if (walletBridgeState.account) addresses.add(walletBridgeState.account)

  walletBridgeState.linkedWalletAddresses.forEach((address) => addresses.add(address))

  return Array.from(addresses)
}

async function completeXmtpIdentity(
  sessionEndpoint: string,
  session: PrivySessionResponse,
): Promise<boolean> {
  if (session.xmtp?.status !== "signature_required") return true

  const xmtp = session.xmtp

  try {
    const signature = await signXmtpSignatureText(xmtp.signature_text, xmtp.wallet_address)

    await fetchJson<PrivySessionResponse>(xmtpCompleteEndpoint(sessionEndpoint), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        wallet_address: xmtp.wallet_address,
        client_id: xmtp.client_id,
        signature_request_id: xmtp.signature_request_id,
        signature,
      }),
    })

    return true
  } catch (error) {
    privyDebugLog("error", "complete-xmtp-identity:failed-after-session", {
      walletAddress: redactWalletForDebug(xmtp.wallet_address),
      ...debugHttpError(error),
    })

    return false
  }
}

async function signXmtpSignatureText(
  message: string,
  expectedAddress: string,
): Promise<`0x${string}`> {
  const wallet = ensureWalletReady()

  if (wallet.account.toLowerCase() !== expectedAddress.toLowerCase()) {
    throw new Error("Switch to the wallet connected to this page first.")
  }

  return wallet.walletClient.signMessage({
    account: wallet.account,
    message,
  })
}

function xmtpCompleteEndpoint(sessionEndpoint: string): string {
  const url = new URL(sessionEndpoint, window.location.origin)
  url.pathname = url.pathname.replace(/\/session$/, "/xmtp/complete")
  return url.pathname + url.search
}

async function refreshIdentityToken(): Promise<string | null> {
  try {
    await walletBridgeState.refreshUser?.()
    walletBridgeState = { ...walletBridgeState, identityToken: null }
  } catch {
    return null
  }

  return resolveIdentityToken()
}

async function resolveIdentityToken(): Promise<string | null> {
  const cachedIdentityToken = walletBridgeState.identityToken?.trim()
  if (cachedIdentityToken) return cachedIdentityToken

  try {
    const freshIdentityToken = await getIdentityToken()

    if (typeof freshIdentityToken === "string" && freshIdentityToken.trim() !== "") {
      walletBridgeState = { ...walletBridgeState, identityToken: freshIdentityToken }
      return freshIdentityToken
    }
  } catch {
    return null
  }

  return null
}
