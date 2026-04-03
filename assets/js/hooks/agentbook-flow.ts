import type { Hook } from "phoenix_live_view"

import { IDKit } from "@worldcoin/idkit-core"
import QRCode from "qrcode"

import { animate } from "../../vendor/anime.esm.js"

interface AgentbookFrontendRequest {
  app_id: string
  action: string
  signal: string
  rp_context: Record<string, unknown>
}

interface AgentbookSession {
  session_id: string
  status: string
  deep_link_uri?: string | null
  frontend_request?: AgentbookFrontendRequest | null
}

interface AgentbookHook extends HTMLElement {
  _agentbookSessionId?: string
  _agentbookRunning?: boolean
}

interface AgentbookHookInstance {
  el: AgentbookHook
  pushEvent(event: string, payload: Record<string, unknown>): void
}

const QR_OPTIONS = {
  margin: 1,
  width: 320,
  color: {
    dark: "#0b1214",
    light: "#f8fbf6",
  },
}

export function parseSession(raw: string | undefined): AgentbookSession | null {
  if (!raw) return null

  try {
    const parsed = JSON.parse(raw) as AgentbookSession
    return parsed && typeof parsed === "object" ? parsed : null
  } catch {
    return null
  }
}

export function buildVerificationConstraints(signal: string) {
  return {
    type: "proof_of_human" as const,
    signal,
  }
}

async function renderQr(root: HTMLElement, connectorUri: string | null | undefined): Promise<void> {
  const image = root.querySelector<HTMLImageElement>("[data-agentbook-qr]")
  const text = root.querySelector<HTMLElement>("[data-agentbook-uri-text]")
  if (!image || !text) return

  text.textContent = connectorUri || "The browser is preparing the World App request."

  if (!connectorUri) {
    image.removeAttribute("src")
    return
  }

  image.src = await QRCode.toDataURL(connectorUri, QR_OPTIONS)

  animate(image, {
    opacity: [0, 1],
    scale: [0.94, 1],
    duration: 420,
    ease: "outExpo",
  })
}

export const AgentBookFlow: Hook = {
  mounted() {
    void runAgentbookFlow(this as unknown as AgentbookHookInstance)
  },

  updated() {
    void runAgentbookFlow(this as unknown as AgentbookHookInstance)
  },
}

async function runAgentbookFlow(hook: AgentbookHookInstance): Promise<void> {
  const session = parseSession(hook.el.dataset.session)
  await renderQr(hook.el, session?.deep_link_uri)

  if (!session || session.status !== "pending" || !session.frontend_request) {
    hook.el._agentbookRunning = false
    return
  }

  if (hook.el._agentbookRunning && hook.el._agentbookSessionId === session.session_id) {
    return
  }

  hook.el._agentbookRunning = true
  hook.el._agentbookSessionId = session.session_id

  try {
    const builder = IDKit.request({
      app_id: session.frontend_request.app_id as `app_${string}`,
      action: session.frontend_request.action,
      rp_context: session.frontend_request.rp_context as {
        rp_id: string
        nonce: string
        created_at: number
        expires_at: number
        signature: string
      },
      allow_legacy_proofs: false,
    })
    const request = await builder.constraints(buildVerificationConstraints(session.frontend_request.signal))

    if (hook.el._agentbookSessionId !== session.session_id) return

    const connectorURI = request.connectorURI || ""
    if (connectorURI) {
      await renderQr(hook.el, connectorURI)
      hook.pushEvent("agentbook_connector_ready", {
        session_id: session.session_id,
        connector_uri: connectorURI,
      })
    }

    const completion = await request.pollUntilCompletion({
      pollInterval: 2_000,
      timeout: 120_000,
    })

    if (hook.el._agentbookSessionId !== session.session_id) return

    if (!completion.success) {
      hook.pushEvent("agentbook_failed", {
        session_id: session.session_id,
        message: completion.error || "Verification failed in World App.",
      })
      return
    }

    hook.pushEvent("agentbook_proof_ready", {
      session_id: session.session_id,
      proof: completion.result,
    })
  } catch (error) {
    hook.pushEvent("agentbook_failed", {
      session_id: session.session_id,
      message: error instanceof Error ? error.message : "World App verification failed.",
    })
  } finally {
    hook.el._agentbookRunning = false
  }
}
