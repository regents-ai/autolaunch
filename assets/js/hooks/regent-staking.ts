import { createPublicClient, erc20Abi, http } from "viem"
import { base, baseSepolia, mainnet } from "viem/chains"

import { normalizeWalletAddress } from "./wallet-bridge-shared"
import { sendWalletBridgeTransaction } from "./wallet-bridge-transactions"
import {
  getWalletBridgeState,
  requestWalletSignature,
  WALLET_STATE_EVENT,
  ensureWalletReady,
} from "./wallet-bridge-runtime"
import { stakingActionNeedsWalletConfirmation } from "./regent-staking-session"

type HookContext = {
  el: HTMLElement
  __regentStakingCleanup?: () => void
  handleEvent: (event: string, callback: (payload: any) => void) => void
  pushEvent: (event: string, payload: Record<string, unknown>) => void
}

function getErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error) {
    const message = error.message.trim()
    return message.length > 0 ? message : fallback
  }

  return fallback
}

function isWalletAddress(value: unknown): value is `0x${string}` {
  return typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value)
}

function isHexData(value: unknown): value is `0x${string}` {
  return typeof value === "string" && /^0x[0-9a-fA-F]*$/.test(value)
}

function chainForId(chainId: number) {
  if (chainId === base.id) return base
  if (chainId === baseSepolia.id) return baseSepolia
  if (chainId === mainnet.id) return mainnet
  throw new Error("Switch to the network used by Regent staking, then try again.")
}

function rpcUrlForChain(
  chainId: number,
  options: { baseRpcUrl?: string; baseSepoliaRpcUrl?: string },
) {
  if (chainId === base.id) return options.baseRpcUrl
  if (chainId === baseSepolia.id) return options.baseSepoliaRpcUrl
  return undefined
}

async function approveRegentIfNeeded(
  walletAction: any,
  options: { baseRpcUrl?: string; baseSepoliaRpcUrl?: string },
): Promise<void> {
  const approval = walletAction.approval
  if (!approval) return

  const token = isWalletAddress(approval.token) ? approval.token : null
  const spender = isWalletAddress(approval.spender) ? approval.spender : null
  const amount = typeof approval.amount === "string" ? BigInt(approval.amount) : null
  const approvalData = isHexData(approval.data) ? approval.data : null

  if (!token || !spender || amount === null || !approvalData) {
    throw new Error("Refresh staking and try again.")
  }

  const wallet = ensureWalletReady()
  const chain = chainForId(walletAction.chain_id)
  const client = createPublicClient({
    chain,
    transport: http(rpcUrlForChain(chain.id, options)),
  })

  const allowance = await client.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [wallet.account, spender],
  })

  if (allowance >= amount) return

  await sendWalletBridgeTransaction(
    {
      chain_id: walletAction.chain_id,
      to: token,
      value: "0",
      data: approvalData,
      expected_signer: walletAction.expected_signer,
    },
    options,
  )
}

export const RegentStakingHook = {
  mounted(this: HookContext) {
    const baseRpcUrl = this.el.dataset.baseRpcUrl ?? undefined
    const baseSepoliaRpcUrl = this.el.dataset.baseSepoliaRpcUrl ?? undefined
    let lastWalletAddress: `0x${string}` | null = null

    const pushWalletState = (walletAddress: `0x${string}` | null) => {
      if (walletAddress === lastWalletAddress) return
      lastWalletAddress = walletAddress

      if (walletAddress) {
        this.pushEvent("wallet_connected", { wallet_address: walletAddress })
      } else {
        this.pushEvent("wallet_disconnected", {})
      }
    }

    const syncConnectedWallet = () => {
      const walletState = getWalletBridgeState()
      const walletAddress =
        walletState.authenticated && walletState.account
          ? normalizeWalletAddress(walletState.account)
          : null

      pushWalletState(walletAddress)
    }

    const onWalletState = () => syncConnectedWallet()

    this.handleEvent("regent-staking:wallet-action", async (payload) => {
      try {
        const walletAction = payload.wallet_action
        const expectedSigner =
          isWalletAddress(walletAction.expected_signer) ? walletAction.expected_signer : null

        if (!expectedSigner) throw new Error("Refresh staking and try again.")

        if (stakingActionNeedsWalletConfirmation(getWalletBridgeState())) {
          requestWalletSignature()
          this.pushEvent("staking_signature_requested", {})
          return
        }

        await approveRegentIfNeeded(walletAction, { baseRpcUrl, baseSepoliaRpcUrl })

        const txHash = await sendWalletBridgeTransaction(
          {
            chain_id: walletAction.chain_id,
            to: walletAction.to,
            value: walletAction.value,
            data: walletAction.data,
            expected_signer: expectedSigner,
          },
          { baseRpcUrl, baseSepoliaRpcUrl },
        )

        this.pushEvent("staking_tx_complete", { tx_hash: txHash, action: payload.action })
      } catch (error) {
        this.pushEvent("staking_tx_failed", {
          action: payload.action,
          message: getErrorMessage(error, "The staking transaction did not finish."),
        })
      }
    })

    window.addEventListener(WALLET_STATE_EVENT, onWalletState)
    syncConnectedWallet()

    this.__regentStakingCleanup = () => {
      window.removeEventListener(WALLET_STATE_EVENT, onWalletState)
    }
  },

  destroyed(this: HookContext) {
    this.__regentStakingCleanup?.()
    this.__regentStakingCleanup = undefined
  },
}
