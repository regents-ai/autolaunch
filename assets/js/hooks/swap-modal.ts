import type { Hook } from "phoenix_live_view"

import { sendWalletBridgeTransaction } from "./wallet-bridge-transactions"
import { getWalletBridgeState, WALLET_STATE_EVENT } from "./wallet-bridge-runtime"

interface SwapModalElement extends HTMLElement {
  __swapModalCleanup?: () => void
}

type SwapSide = "buy" | "sell"

type SwapQuote = {
  side: SwapSide
  chain_id: number
  token_address: string
  token_in: string
  token_out: string
  amount_in_raw: string
  amount_out_raw: string
  minimum_amount_out_raw: string
  route_label: string
  approval: WalletAction | null
  price_impact_percent: string | null
  gas_fee: string | null
}

type WalletAction = {
  action_id: string
  owner_product: "autolaunch"
  resource: string
  resource_id: string
  action: string
  chain_id: number
  to: string
  value: string
  data: string
  expected_signer: string
  expires_at: string
  idempotency_key: string
  simulation: {
    required: boolean
    status: "not_required" | "pending" | "passed" | "failed"
    block_number?: number | null
  }
  risk_copy: string
}

type ActiveSwap = {
  side: SwapSide
  chainId: number
  tokenAddress: string
}

type QuoteEnvelope = { ok: boolean; quote: SwapQuote }
type PrepareEnvelope = { ok: boolean; swap: { wallet_action: WalletAction; quote: SwapQuote } }

export const SwapModal: Hook = {
  mounted() {
    mountSwapModal(this.el as SwapModalElement)
  },

  updated() {
    mountSwapModal(this.el as SwapModalElement)
  },

  destroyed() {
    const el = this.el as SwapModalElement
    el.__swapModalCleanup?.()
    el.__swapModalCleanup = undefined
  },
}

function mountSwapModal(el: SwapModalElement) {
  el.__swapModalCleanup?.()
  el.__swapModalCleanup = bindSwapModal(el)
}

function bindSwapModal(el: HTMLElement): () => void {
  const dialog = el.querySelector<HTMLElement>("[data-swap-dialog]")
  const title = el.querySelector<HTMLElement>("[data-swap-title]")
  const copy = el.querySelector<HTMLElement>("[data-swap-copy]")
  const amount = el.querySelector<HTMLInputElement>("[data-swap-amount]")
  const slippage = el.querySelector<HTMLInputElement>("[data-swap-slippage]")
  const quoteButton = el.querySelector<HTMLButtonElement>("[data-swap-quote]")
  const submitButton = el.querySelector<HTMLButtonElement>("[data-swap-submit]")
  const connectButton = el.querySelector<HTMLButtonElement>("[data-swap-connect]")
  const closeButtons = Array.from(el.querySelectorAll<HTMLButtonElement>("[data-swap-close]"))
  const notice = el.querySelector<HTMLElement>("[data-swap-notice]")
  const quotePanel = el.querySelector<HTMLElement>("[data-swap-quote-panel]")

  let active: {
    side: SwapSide
    chainId: number
    tokenAddress: string
    tokenSymbol: string
    agentName: string
  } | null = null
  let quoted: SwapQuote | null = null
  let quotedRequestKey: string | null = null
  let busy = false

  const open = (button: HTMLElement) => {
    const side = button.dataset.swapSide === "sell" ? "sell" : "buy"
    const chainId = Number(button.dataset.swapChainId || "")
    const tokenAddress = button.dataset.swapToken || ""
    const tokenSymbol = button.dataset.swapSymbol || "TOKEN"
    const agentName = button.dataset.swapAgent || "agent token"

    if (!Number.isInteger(chainId) || !tokenAddress) {
      showNotice("This token is not ready for in-app swaps.", "error")
      return
    }

    active = { side, chainId, tokenAddress, tokenSymbol, agentName }
    quoted = null
    quotedRequestKey = null
    if (amount) amount.value = ""
    if (slippage) slippage.value = "1"
    renderOpenState()
    el.removeAttribute("hidden")
    window.requestAnimationFrame(() => dialog?.focus())
  }

  const close = () => {
    el.setAttribute("hidden", "")
    active = null
    quoted = null
    quotedRequestKey = null
    setBusy(false)
  }

  const renderOpenState = (options: { preserveNotice?: boolean } = {}) => {
    if (!active) return

    const connected = walletConnected()
    const verb = active.side === "buy" ? "Buy" : "Sell"
    const inputToken = active.side === "buy" ? "USDC" : active.tokenSymbol

    if (title) title.textContent = `${verb} ${active.tokenSymbol}`
    if (copy) copy.textContent = `${active.agentName} trades through Base Uniswap v4. Enter the ${inputToken} amount you want to spend.`

    if (amount) {
      amount.disabled = !connected || busy
      amount.placeholder = active.side === "buy" ? "100" : "1000"
    }

    if (slippage) slippage.disabled = !connected || busy
    if (quoteButton) quoteButton.disabled = !connected || busy
    if (submitButton) submitButton.disabled = !connected || busy || !quoted
    if (connectButton) connectButton.hidden = connected

    if (options.preserveNotice) {
      renderQuote()
      return
    }

    if (!connected) {
      showNotice("Connect your wallet to quote and trade.", "info")
    } else if (!quoted) {
      showNotice(active.side === "buy" ? "You need Base USDC and ETH for gas." : "You need this token and ETH for gas.", "info")
    }

    renderQuote()
  }

  const renderQuote = () => {
    if (!quotePanel) return

    if (!quoted) {
      quotePanel.hidden = true
      quotePanel.innerHTML = ""
      return
    }

    quotePanel.hidden = false
    quotePanel.replaceChildren(
      quoteRow("Estimated receive", formatUnits(quoted.amount_out_raw, active?.side === "buy" ? 18 : 6)),
      quoteRow("Minimum receive", formatUnits(quoted.minimum_amount_out_raw, active?.side === "buy" ? 18 : 6)),
      quoteRow("Route", quoted.route_label || "Uniswap v4"),
      quoteRow("Price impact", quoted.price_impact_percent ? `${quoted.price_impact_percent}%` : "Not available"),
    )
  }

  const quote = async () => {
    if (!active || !amount || !slippage) return

    const account = connectedAccount()
    if (!account) {
      renderOpenState()
      return
    }

    setBusy(true)
    showNotice("Checking the market...", "info")

    try {
      const key = requestKey(active, account, amount.value, slippage.value)
      const response = await postJson<QuoteEnvelope>("/v1/app/swaps/quote", requestBody(active, account, amount.value, slippage.value))
      quoted = response.quote
      quotedRequestKey = key
      showNotice(quoted.approval ? "Approval is needed before the swap." : "Quote ready.", "success")
      renderOpenState()
    } catch (error) {
      quoted = null
      quotedRequestKey = null
      showNotice(errorMessage(error, "Quote is not available right now."), "error")
      renderOpenState({ preserveNotice: true })
    } finally {
      setBusy(false)
    }
  }

  const submit = async () => {
    if (!active || !quoted || !amount || !slippage) return

    const account = connectedAccount()
    if (!account) {
      renderOpenState()
      return
    }

    if (quotedRequestKey !== requestKey(active, account, amount.value, slippage.value)) {
      clearQuote("Get a fresh quote before swapping.")
      return
    }

    setBusy(true)

    try {
      if (quoted.approval) {
        showNotice("Approving the spend...", "info")
        await sendWalletAction(account, quoted.approval)
      }

      showNotice("Preparing the swap...", "info")
      const key = requestKey(active, account, amount.value, slippage.value)
      const prepared = await postJson<PrepareEnvelope>("/v1/app/swaps/prepare", requestBody(active, account, amount.value, slippage.value))
      const preparedQuote = prepared.swap.quote

      if (preparedQuote.approval || !sameQuoteTerms(quoted, preparedQuote)) {
        quoted = preparedQuote
        quotedRequestKey = key
        setBusy(false)
        renderOpenState({ preserveNotice: true })
        showNotice(
          preparedQuote.approval
            ? "Approval is still needed. Review the updated quote, then swap again."
            : "Market price changed. Review the updated quote, then swap again.",
          "info",
        )
        return
      }

      quoted = preparedQuote
      quotedRequestKey = key

      showNotice("Confirm the swap in your wallet.", "info")
      await sendWalletAction(account, prepared.swap.wallet_action)

      showNotice("Swap confirmed.", "success")
      window.setTimeout(() => window.location.reload(), 900)
    } catch (error) {
      showNotice(errorMessage(error, "Swap failed."), "error")
      setBusy(false)
    }
  }

  const connect = () => {
    const state = getWalletBridgeState()
    showNotice("Confirm your wallet to continue.", "info")

    if (state.authenticated && state.linkWallet) {
      state.linkWallet()
      return
    }

    state.login?.()
  }

  const onClick = (event: Event) => {
    const target = event.target as HTMLElement | null
    const trigger = target?.closest<HTMLElement>("[data-swap-open]")
    if (trigger) {
      event.preventDefault()
      open(trigger)
    }
  }

  const onWalletState = () => renderOpenState()
  const onQuoteInput = () => clearQuote("Get a fresh quote before swapping.")

  document.addEventListener("click", onClick)
  window.addEventListener(WALLET_STATE_EVENT, onWalletState)
  closeButtons.forEach((button) => button.addEventListener("click", close))
  amount?.addEventListener("input", onQuoteInput)
  slippage?.addEventListener("input", onQuoteInput)
  quoteButton?.addEventListener("click", quote)
  submitButton?.addEventListener("click", submit)
  connectButton?.addEventListener("click", connect)

  return () => {
    document.removeEventListener("click", onClick)
    window.removeEventListener(WALLET_STATE_EVENT, onWalletState)
    closeButtons.forEach((button) => button.removeEventListener("click", close))
    amount?.removeEventListener("input", onQuoteInput)
    slippage?.removeEventListener("input", onQuoteInput)
    quoteButton?.removeEventListener("click", quote)
    submitButton?.removeEventListener("click", submit)
    connectButton?.removeEventListener("click", connect)
  }

  function clearQuote(message: string) {
    if (!quoted) return

    quoted = null
    quotedRequestKey = null
    renderOpenState({ preserveNotice: true })
    showNotice(message, "info")
  }

  function setBusy(next: boolean) {
    busy = next
    if (quoteButton) quoteButton.disabled = next
    if (submitButton) submitButton.disabled = next || !quoted
    if (amount) amount.disabled = next || !walletConnected()
    if (slippage) slippage.disabled = next || !walletConnected()
  }

  function showNotice(message: string, tone: "info" | "success" | "error") {
    if (!notice) return
    notice.hidden = false
    notice.textContent = message
    notice.dataset.tone = tone
  }
}

function walletConnected(): boolean {
  return Boolean(connectedAccount())
}

function connectedAccount(): string | null {
  const state = getWalletBridgeState()
  if (!state.authenticated || !state.account) return null
  return state.account
}

function requestBody(active: ActiveSwap, account: string, amount: string, slippage: string) {
  return {
    side: active.side,
    chain_id: active.chainId,
    token_address: active.tokenAddress,
    amount,
    slippage_bps: Math.round(Number(slippage || "1") * 100),
    swapper: account,
  }
}

function requestKey(active: ActiveSwap, account: string, amount: string, slippage: string): string {
  return [
    active.side,
    active.chainId,
    active.tokenAddress.toLowerCase(),
    account.toLowerCase(),
    amount.trim(),
    slippage.trim(),
  ].join(":")
}

function sameQuoteTerms(current: SwapQuote, prepared: SwapQuote): boolean {
  return current.side === prepared.side
    && current.chain_id === prepared.chain_id
    && current.token_address.toLowerCase() === prepared.token_address.toLowerCase()
    && current.token_in.toLowerCase() === prepared.token_in.toLowerCase()
    && current.token_out.toLowerCase() === prepared.token_out.toLowerCase()
    && current.amount_in_raw === prepared.amount_in_raw
    && current.amount_out_raw === prepared.amount_out_raw
    && current.minimum_amount_out_raw === prepared.minimum_amount_out_raw
    && current.route_label === prepared.route_label
    && current.price_impact_percent === prepared.price_impact_percent
}

async function postJson<T>(url: string, body: Record<string, unknown>): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content ?? "",
    },
    body: JSON.stringify(body),
  })

  const payload = await response.json().catch(() => ({})) as {
    error?: { message?: unknown }
    message?: unknown
  }
  if (!response.ok) {
    const message = typeof payload?.error?.message === "string"
      ? payload.error.message
      : typeof payload?.message === "string"
        ? payload.message
        : "Request failed."
    throw new Error(message)
  }

  return payload as T
}

async function sendWalletAction(from: string, action: WalletAction): Promise<void> {
  if (action.expected_signer.toLowerCase() !== from.toLowerCase()) {
    throw new Error("Switch to the expected wallet before signing.")
  }

  await sendWalletBridgeTransaction(
    {
      chain_id: action.chain_id,
      to: action.to as `0x${string}`,
      data: action.data as `0x${string}`,
      value: hexQuantity(action.value),
      expected_signer: action.expected_signer as `0x${string}`,
    },
    { failureMessage: "The swap did not finish successfully." },
  )
}

function hexQuantity(value: string): string {
  if (/^0x[0-9a-fA-F]+$/.test(value)) return `0x${BigInt(value).toString(16)}`
  throw new Error("Wallet action is not available.")
}

function quoteRow(label: string, value: string): HTMLDivElement {
  const row = document.createElement("div")
  const labelEl = document.createElement("span")
  const valueEl = document.createElement("strong")
  labelEl.textContent = label
  valueEl.textContent = value
  row.append(labelEl, valueEl)
  return row
}

function formatUnits(raw: unknown, decimals: number): string {
  if (typeof raw !== "string" || !/^[0-9]+$/.test(raw)) return "Not available"
  const padded = raw.padStart(decimals + 1, "0")
  const whole = padded.slice(0, -decimals)
  const fraction = padded.slice(-decimals).replace(/0+$/, "").slice(0, 6)
  return fraction ? `${whole}.${fraction}` : whole
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback
}
