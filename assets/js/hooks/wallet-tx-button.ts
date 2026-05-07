import type { Hook } from "phoenix_live_view"

interface EthereumProvider {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>
}

interface TransactionReceipt {
  status?: string
}

interface ApprovalPayload {
  token: string
  spender: string
  amount: bigint
  data: string
}

interface WalletTxHookInstance {
  el: HTMLElement
  pushEvent(event: string, payload: Record<string, unknown>): void
  handleClick?: EventListener
}

const POLL_INTERVAL_MS = 2_000
const MAX_POLLS = 45

function csrfToken(): string {
  return document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() ?? ""
}

function parseJsonAttr(value: string | undefined): Record<string, unknown> {
  if (!value) return {}

  try {
    const parsed = JSON.parse(value) as Record<string, unknown>
    return parsed && typeof parsed === "object" ? parsed : {}
  } catch {
    return {}
  }
}

function hexChainId(chainId: number): string {
  return `0x${chainId.toString(16)}`
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
}

function firstRequestedAccount(result: unknown): string {
  return Array.isArray(result) ? String(result[0] ?? "") : ""
}

function normalizeAddress(value: unknown): string | null {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) return null
  return value.toLowerCase()
}

function isHexData(value: unknown): value is string {
  return typeof value === "string" && /^0x[0-9a-fA-F]*$/.test(value)
}

function hexQuantity(value: unknown): string {
  if (typeof value !== "string") return "0x0"

  const trimmed = value.trim()
  if (!trimmed) return "0x0"
  if (/^0x[0-9a-fA-F]+$/.test(trimmed)) return `0x${BigInt(trimmed).toString(16)}`
  if (/^[0-9]+$/.test(trimmed)) return `0x${BigInt(trimmed).toString(16)}`

  throw new Error("Wallet action has an invalid transaction value.")
}

function encodeAddressWord(address: string): string {
  return address.replace(/^0x/, "").padStart(64, "0")
}

function allowanceCallData(owner: string, spender: string): string {
  return `0xdd62ed3e${encodeAddressWord(owner)}${encodeAddressWord(spender)}`
}

function decodeUint256(result: unknown): bigint {
  if (!isHexData(result) || result.length === 2) {
    throw new Error("Could not read the current REGENT approval.")
  }

  return BigInt(result)
}

function approvalFromPayload(payload: Record<string, unknown>): ApprovalPayload | null {
  if (Object.keys(payload).length === 0) return null

  const token = normalizeAddress(payload.token)
  const spender = normalizeAddress(payload.spender)
  const amount = typeof payload.amount === "string" && /^[0-9]+$/.test(payload.amount)
    ? BigInt(payload.amount)
    : null
  const data = isHexData(payload.data) ? payload.data : null

  if (!token || !spender || amount === null || !data) {
    throw new Error("Refresh staking and try again.")
  }

  return { token, spender, amount, data }
}

async function ensureWalletChain(ethereum: EthereumProvider, chainId: number): Promise<void> {
  const current = (await ethereum.request({ method: "eth_chainId" })) as string
  if (parseInt(current, 16) === chainId) return

  await ethereum.request({
    method: "wallet_switchEthereumChain",
    params: [{ chainId: hexChainId(chainId) }],
  })
}

async function registerConfirmedTx(
  endpoint: string,
  baseBody: Record<string, unknown>,
  txHash: string,
): Promise<void> {
  const headers: Record<string, string> = {
    accept: "application/json",
    "content-type": "application/json",
  }

  const token = csrfToken()
  if (token) headers["x-csrf-token"] = token

  for (let attempt = 0; attempt < MAX_POLLS; attempt += 1) {
    const response = await fetch(endpoint, {
      method: "POST",
      headers,
      credentials: "same-origin",
      body: JSON.stringify({ ...baseBody, tx_hash: txHash }),
    })

    const payload = (await response.json().catch(() => ({}))) as {
      ok?: boolean
      error?: { code?: string; message?: string }
    }

    if (response.status === 202 || payload.error?.code === "transaction_pending") {
      await sleep(POLL_INTERVAL_MS)
      continue
    }

    if (!response.ok || payload.ok === false) {
      throw new Error(payload.error?.message || "Failed to register transaction.")
    }

    return
  }

  throw new Error("Timed out waiting for chain confirmation.")
}

async function waitForReceipt(ethereum: EthereumProvider, txHash: string): Promise<void> {
  for (let attempt = 0; attempt < MAX_POLLS; attempt += 1) {
    const receipt = (await ethereum.request({
      method: "eth_getTransactionReceipt",
      params: [txHash],
    })) as TransactionReceipt | null

    if (!receipt) {
      await sleep(POLL_INTERVAL_MS)
      continue
    }

    if (receipt.status === "0x1") return
    if (receipt.status === "0x0") throw new Error("Transaction reverted onchain.")

    await sleep(POLL_INTERVAL_MS)
  }

  throw new Error("Timed out waiting for chain confirmation.")
}

async function approveIfNeeded(
  ethereum: EthereumProvider,
  from: string,
  approval: ApprovalPayload,
): Promise<void> {
  const allowance = decodeUint256(await ethereum.request({
    method: "eth_call",
    params: [
      {
        to: approval.token,
        data: allowanceCallData(from, approval.spender),
      },
      "latest",
    ],
  }))

  if (allowance >= approval.amount) return

  const approvalHash = (await ethereum.request({
    method: "eth_sendTransaction",
    params: [
      {
        from,
        to: approval.token,
        data: approval.data,
        value: "0x0",
      },
    ],
  })) as string

  await waitForReceipt(ethereum, approvalHash)
}

export const WalletTxButton: Hook = {
  mounted() {
    const hook = this as unknown as WalletTxHookInstance
    const onClick = async () => {
      const button = hook.el as HTMLButtonElement
      if (button.disabled) return

      const ethereum = window.ethereum as EthereumProvider | undefined
      if (!ethereum) {
        hook.pushEvent("wallet_tx_error", { message: "Connect an EVM wallet in this browser first." })
        return
      }

      const chainId = Number(button.dataset.chainId || "")
      const to = button.dataset.to || ""
      const data = button.dataset.data || ""
      const value = button.dataset.value || "0x0"
      const expectedSigner = normalizeAddress(button.dataset.expectedSigner)
      const approvalPayload = parseJsonAttr(button.dataset.approval)
      const registerEndpoint = button.dataset.registerEndpoint || ""
      const registerBody = parseJsonAttr(button.dataset.registerBody)
      const pendingMessage = button.dataset.pendingMessage || "Transaction sent. Waiting for confirmation."
      const successMessage = button.dataset.successMessage || "Transaction confirmed."

      if (!Number.isInteger(chainId) || !to || !data) {
        hook.pushEvent("wallet_tx_error", { message: "Wallet action is missing required transaction data." })
        return
      }

      button.disabled = true
      hook.pushEvent("wallet_tx_started", { message: pendingMessage })

      try {
        const approval = approvalFromPayload(approvalPayload)
        const from = normalizeAddress(firstRequestedAccount(await ethereum.request({ method: "eth_requestAccounts" })))
        if (!from) throw new Error("Wallet connection was cancelled.")
        if (expectedSigner && from !== expectedSigner) {
          throw new Error("Switch to the expected wallet, then try again.")
        }

        await ensureWalletChain(ethereum, chainId)
        if (approval) await approveIfNeeded(ethereum, from, approval)

        const txHash = (await ethereum.request({
          method: "eth_sendTransaction",
          params: [{ from, to, data, value: hexQuantity(value) }],
        })) as string

        if (registerEndpoint) {
          await registerConfirmedTx(registerEndpoint, registerBody, txHash)
        } else {
          await waitForReceipt(ethereum, txHash)
        }

        hook.pushEvent("wallet_tx_registered", { message: successMessage, tx_hash: txHash })
      } catch (error) {
        const message = error instanceof Error ? error.message : "Wallet transaction failed."
        hook.pushEvent("wallet_tx_error", { message })
      } finally {
        button.disabled = false
      }
    }

    hook.handleClick = onClick
    hook.el.addEventListener("click", onClick)
  },

  destroyed() {
    const hook = this as unknown as WalletTxHookInstance
    if (hook.handleClick) {
      hook.el.removeEventListener("click", hook.handleClick)
    }
  },
}
