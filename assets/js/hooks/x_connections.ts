import {browserCsrfToken} from "../auth_lazy"
import type {Hook} from "../hook_composition"

type XRole = "profile" | "company"
type StartResponse = {url?: unknown; role?: unknown; generation?: unknown; error?: unknown}
type CallbackMessage = {
  source?: unknown
  status?: unknown
  role?: unknown
  generation?: unknown
}
type Intent = {sequence: number; generation: string}
type StartAttempt = {
  role: XRole
  intent: Intent
  controller: AbortController
  timeout: number
  cancelled: boolean
}
type DeleteAttempt = {
  path: string
  cancelGeneration?: unknown
  controller: AbortController
  timeout: number
  promise: Promise<Response>
}

type XConnectionsHook = Hook & {
  el: HTMLElement
  pushEvent(event: string, payload: unknown): void
  activeStart?: StartAttempt
  activeDeletes?: Partial<Record<XRole, DeleteAttempt>>
  disconnectingRoles?: Set<XRole>
  intentSequences?: Partial<Record<XRole, number>>
  cancelActiveStart?: (selectedRole?: XRole) => void
  activePopup?: Window | null
  activeRole?: XRole
  activeIntent?: Intent
  activeGeneration?: string
  popupPoll?: number
  clickListener?: (event: Event) => void
  messageListener?: (event: MessageEvent) => void
}

const requestTimeoutMs = 10_000

function role(value: string | undefined): XRole | null {
  return value === "profile" || value === "company" ? value : null
}

function status(root: HTMLElement, message: string): void {
  const target = root.querySelector<HTMLElement>("[data-x-connection-status]")
  if (target) target.textContent = message
}

async function json(response: Response): Promise<StartResponse> {
  try {
    return (await response.json()) as StartResponse
  } catch {
    return {}
  }
}

async function mutate(
  path: string,
  method: "POST" | "DELETE",
  payload: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<Response> {
  return fetch(path, {
    method,
    credentials: "same-origin",
    headers: {
      "x-csrf-token": browserCsrfToken(),
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
    ...(signal ? {signal} : {}),
  })
}

export const XConnections: Hook = {
  mounted(this: XConnectionsHook) {
    this.activeDeletes = {}
    this.disconnectingRoles = new Set()
    this.intentSequences = {}

    const resetPopup = () => {
      if (this.popupPoll) window.clearInterval(this.popupPoll)
      this.popupPoll = undefined
      this.activePopup = null
      this.activeRole = undefined
      this.activeIntent = undefined
      this.activeGeneration = undefined
    }

    const releaseStart = (attempt: StartAttempt) => {
      window.clearTimeout(attempt.timeout)
      if (this.activeStart === attempt) this.activeStart = undefined
    }

    const nextIntent = (selectedRole: XRole, renderedSequence = 0): Intent => {
      const previous = Math.max(this.intentSequences?.[selectedRole] ?? 0, renderedSequence)
      const clock = Math.min(Number.MAX_SAFE_INTEGER - 1, Date.now() * 1_000)
      const sequence = Math.max(previous + 1, clock)
      if (this.intentSequences) this.intentSequences[selectedRole] = sequence
      return {sequence, generation: crypto.randomUUID()}
    }

    const runDelete = (
      selectedRole: XRole,
      path: string,
      payload: Record<string, unknown>,
    ): Promise<Response> => {
      const active = this.activeDeletes?.[selectedRole]
      if (
        active &&
        active.path === path &&
        active.cancelGeneration === payload.cancel_generation
      ) {
        return active.promise
      }

      if (active) {
        return active.promise.then(
          () => runDelete(selectedRole, path, payload),
          () => runDelete(selectedRole, path, payload),
        )
      }

      const controller = new AbortController()
      const attempt = {} as DeleteAttempt
      attempt.path = path
      attempt.cancelGeneration = payload.cancel_generation
      attempt.controller = controller
      attempt.timeout = window.setTimeout(() => controller.abort(), requestTimeoutMs)
      attempt.promise = mutate(path, "DELETE", payload, controller.signal).finally(() => {
        window.clearTimeout(attempt.timeout)
        if (this.activeDeletes?.[selectedRole] === attempt) {
          delete this.activeDeletes[selectedRole]
        }
      })

      if (this.activeDeletes) this.activeDeletes[selectedRole] = attempt
      return attempt.promise
    }

    const cancelAttempt = (selectedRole: XRole, target: Intent, renderedSequence = 0) => {
      const cancellation = nextIntent(selectedRole, Math.max(renderedSequence, target.sequence))

      return runDelete(selectedRole, `/auth/x/connections/${selectedRole}/attempt`, {
        intent_sequence: cancellation.sequence,
        intent_generation: cancellation.generation,
        cancel_sequence: target.sequence,
        cancel_generation: target.generation,
      })
    }

    const cancelStart = (selectedRole?: XRole) => {
      const attempt = this.activeStart
      const popupRole = this.activeRole
      const popupIntent = this.activeIntent

      if (attempt && (!selectedRole || attempt.role === selectedRole)) {
        attempt.controller.abort()
        releaseStart(attempt)
      }

      if (
        popupRole &&
        popupIntent &&
        (!selectedRole || popupRole === selectedRole) &&
        !attempt?.cancelled
      ) {
        if (attempt) attempt.cancelled = true
        void cancelAttempt(popupRole, popupIntent).catch(() => undefined)
      }
    }

    this.cancelActiveStart = cancelStart

    const start = (selectedRole: XRole, renderedSequence: number) => {
      cancelStart()
      this.activePopup?.close()
      resetPopup()

      const popup = window.open("", "autolaunch-x-oauth", "popup,width=620,height=720")
      if (!popup) {
        status(this.el, "Allow popups to connect X.")
        return
      }

      const intent = nextIntent(selectedRole, renderedSequence)
      const attempt: StartAttempt = {
        role: selectedRole,
        intent,
        controller: new AbortController(),
        timeout: 0,
        cancelled: false,
      }

      this.activeStart = attempt
      this.activePopup = popup
      this.activeRole = selectedRole
      this.activeIntent = intent
      this.activeGeneration = undefined
      popup.document.title = "Connecting X"
      status(this.el, `Opening ${selectedRole} X connection…`)

      const abandon = (message: string) => {
        if (this.activePopup !== popup) return
        cancelStart(selectedRole)
        popup.close()
        resetPopup()
        status(this.el, message)
      }

      this.popupPoll = window.setInterval(() => {
        if (this.activePopup === popup && popup.closed) {
          abandon("X connection was not completed.")
        }
      }, 250)

      attempt.timeout = window.setTimeout(() => {
        if (this.activePopup === popup) abandon("X connection could not start. Try again.")
      }, requestTimeoutMs)

      void (async () => {
        try {
          const response = await mutate(
            `/auth/x/connections/${selectedRole}`,
            "POST",
            {
              intent_sequence: intent.sequence,
              intent_generation: intent.generation,
            },
            attempt.controller.signal,
          )
          const body = await json(response)
          if (
            !response.ok ||
            body.role !== selectedRole ||
            typeof body.url !== "string" ||
            typeof body.generation !== "string"
          ) {
            throw new Error("start refused")
          }

          if (this.activePopup !== popup || popup.closed || attempt.controller.signal.aborted) {
            if (!attempt.cancelled) {
              attempt.cancelled = true
              void cancelAttempt(selectedRole, intent).catch(() => undefined)
            }
            return
          }

          this.activeGeneration = body.generation
          popup.location.replace(body.url)
        } catch {
          if (!attempt.cancelled) {
            attempt.cancelled = true
            void cancelAttempt(selectedRole, intent).catch(() => undefined)
          }

          if (!attempt.controller.signal.aborted) popup.close()

          if (this.activePopup === popup && !attempt.controller.signal.aborted) {
            resetPopup()
            status(this.el, "X connection could not start. Try again.")
          }
        } finally {
          releaseStart(attempt)
        }
      })()
    }

    const disconnect = (selectedRole: XRole, renderedSequence: number) => {
      if (this.disconnectingRoles?.has(selectedRole)) {
        status(this.el, `Disconnecting ${selectedRole} X…`)
        return
      }

      this.disconnectingRoles?.add(selectedRole)

      const activeIntent = this.activeRole === selectedRole ? this.activeIntent : undefined
      const startAttempt = this.activeStart

      if (startAttempt?.role === selectedRole) {
        startAttempt.cancelled = true
        startAttempt.controller.abort()
        releaseStart(startAttempt)
      }

      if (this.activeRole === selectedRole) {
        this.activePopup?.close()
        resetPopup()
      }

      const intent = nextIntent(
        selectedRole,
        Math.max(renderedSequence, activeIntent?.sequence ?? 0),
      )
      status(this.el, `Disconnecting ${selectedRole} X…`)

      void (async () => {
        try {
          const response = await runDelete(selectedRole, `/auth/x/connections/${selectedRole}`, {
            intent_sequence: intent.sequence,
            intent_generation: intent.generation,
            ...(activeIntent ? {cancel_generation: activeIntent.generation} : {}),
          })
          if (!response.ok) throw new Error("disconnect refused")
          status(this.el, "X account disconnected.")
          this.pushEvent("refresh_x_connections", {role: selectedRole, status: "disconnected"})
        } catch {
          status(this.el, "X account could not be disconnected. Try again.")
        } finally {
          this.disconnectingRoles?.delete(selectedRole)
        }
      })()
    }

    this.clickListener = event => {
      const target = event.target instanceof Element ? event.target : null
      const roleContainer = target?.closest<HTMLElement>("[data-x-role]")
      const renderedSequence = Number(roleContainer?.dataset.xIntentSequence ?? "0")
      const connectRole = role(
        target?.closest<HTMLElement>("[data-x-connect-role]")?.dataset.xConnectRole,
      )
      const disconnectRole = role(
        target?.closest<HTMLElement>("[data-x-disconnect-role]")?.dataset.xDisconnectRole,
      )
      if (connectRole) start(connectRole, renderedSequence)
      if (disconnectRole) disconnect(disconnectRole, renderedSequence)
    }

    this.messageListener = event => {
      const expectedOrigin = this.el.dataset.xOauthOrigin
      const message = event.data as CallbackMessage
      if (
        event.origin !== expectedOrigin ||
        event.source !== this.activePopup ||
        message?.source !== "autolaunch-x-oauth" ||
        message.role !== this.activeRole ||
        message.generation !== this.activeGeneration
      ) {
        return
      }

      const selectedRole = this.activeRole
      this.activePopup?.close()
      resetPopup()
      if (message.status === "connected") {
        status(this.el, "X account connected.")
        this.pushEvent("refresh_x_connections", {role: selectedRole, status: "connected"})
      } else {
        status(this.el, "X connection was not completed.")
      }
    }

    this.el.addEventListener("click", this.clickListener)
    window.addEventListener("message", this.messageListener)
  },

  destroyed(this: XConnectionsHook) {
    this.cancelActiveStart?.()
    this.activePopup?.close()
    if (this.popupPoll) window.clearInterval(this.popupPoll)
    if (this.clickListener) this.el.removeEventListener("click", this.clickListener)
    if (this.messageListener) window.removeEventListener("message", this.messageListener)
  },
}
