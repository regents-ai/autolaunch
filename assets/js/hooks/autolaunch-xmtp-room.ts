import type { Hook } from "phoenix_live_view"

import { animate, stagger } from "../../vendor/anime.esm.js"
import { requireEthereumProvider, signWithConnectedWallet } from "./privy-wallet.ts"

type PublicRoomRoot = HTMLElement & {
  __publicChatSeenKeys?: Set<string>
  __publicChatLastStatus?: string
  __publicChatHeartbeat?: number
}

function animateStatus(el: HTMLElement | null, nextStatus: string, force = false): void {
  if (!el) return
  if (!force && el.textContent === nextStatus) return

  el.textContent = nextStatus

  animate(el, {
    opacity: [0.58, 1],
    translateY: [-4, 0],
    duration: 240,
    ease: "outQuad",
  })
}

function animateEntries(root: PublicRoomRoot, initial = false): void {
  const seenKeys = root.__publicChatSeenKeys ?? new Set<string>()
  const feed = root.querySelector<HTMLElement>("[data-public-chat-feed]")
  const entries = Array.from(root.querySelectorAll<HTMLElement>("[data-public-chat-entry]"))

  const newEntries = entries.filter((entry) => {
    const key = entry.dataset.messageKey || entry.id
    if (seenKeys.has(key)) return false

    seenKeys.add(key)
    return true
  })

  root.__publicChatSeenKeys = seenKeys

  const shouldAutoScroll = feed && (initial || (newEntries.length > 0 && isNearBottom(feed)))
  if (shouldAutoScroll) {
    requestAnimationFrame(() => {
      feed.scrollTop = feed.scrollHeight
    })
  }

  if (!initial && newEntries.length > 0) {
    animate(newEntries, {
      opacity: [0, 1],
      translateY: [14, 0],
      scale: [0.985, 1],
      delay: stagger(60),
      duration: 340,
      ease: "outExpo",
    })
  }
}

function isNearBottom(el: HTMLElement, threshold = 72): boolean {
  return el.scrollHeight - el.scrollTop - el.clientHeight <= threshold
}

export const AutolaunchXmtpRoom: Hook = {
  mounted() {
    const root = this.el as PublicRoomRoot
    const status = root.querySelector<HTMLElement>("[data-public-chat-status]")

    root.__publicChatLastStatus = status?.textContent ?? ""
    animateEntries(root, true)

    root.__publicChatHeartbeat = window.setInterval(() => {
      this.pushEvent("public_chat_heartbeat", {})
    }, 30_000)

    this.handleEvent("xmtp:sign-request", async (payload) => {
      const { request_id, signature_text, wallet_address } = payload as {
        request_id: string
        signature_text: string
        wallet_address?: string | null
      }

      try {
        animateStatus(status, "Check your wallet to finish joining.", true)

        const provider = await requireEthereumProvider()
        const { signature } = await signWithConnectedWallet(
          provider,
          String(signature_text ?? ""),
          typeof wallet_address === "string" ? wallet_address : null,
        )

        animateStatus(status, "Joining room...", true)

        this.pushEvent("public_chat_join_signature_signed", {
          request_id,
          signature,
        })
      } catch {
        const message = "Joining was not finished. Try again when you are ready."

        animateStatus(status, message, true)
        this.pushEvent("public_chat_join_signature_failed", { message })
      }
    })
  },

  updated() {
    const root = this.el as PublicRoomRoot
    const status = root.querySelector<HTMLElement>("[data-public-chat-status]")
    const nextStatus = status?.textContent ?? ""

    if (root.__publicChatLastStatus !== nextStatus) {
      root.__publicChatLastStatus = nextStatus
      animateStatus(status, nextStatus, true)
    }

    animateEntries(root)
  },

  destroyed() {
    const root = this.el as PublicRoomRoot

    if (root.__publicChatHeartbeat) {
      window.clearInterval(root.__publicChatHeartbeat)
    }
  },
}
