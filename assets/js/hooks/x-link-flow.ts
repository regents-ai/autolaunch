import type { Hook } from "phoenix_live_view"

import { LocalStorage, Privy } from "../../vendor/privy-core.esm.js"

const PROVIDER_STORAGE_KEY = "autolaunch:x-link:oauth-provider"
const AGENT_STORAGE_KEY = "autolaunch:x-link:agent-id"

type LinkedAccount = {
  type?: string
  provider?: string
  username?: string
  handle?: string
  profile_url?: string
  subject?: string
  provider_subject?: string
  id?: string
  user_id?: string
  name?: string
}

type PrivyUser = {
  linked_accounts?: LinkedAccount[]
} | null

function csrfHeaders(csrfToken: string): Record<string, string> {
  return csrfToken ? { "x-csrf-token": csrfToken } : {}
}

function normalizeHandle(value: string | undefined): string | null {
  if (!value) return null
  const trimmed = value.trim().replace(/^@+/, "")
  return trimmed.length > 0 ? trimmed : null
}

function findXAccount(user: PrivyUser): {
  handle: string
  profileUrl: string
  providerSubject: string
} | null {
  const accounts = user?.linked_accounts ?? []

  for (const account of accounts) {
    const provider = (account.provider ?? account.type ?? "").toLowerCase()
    if (!(provider.includes("twitter") || provider === "x")) {
      continue
    }

    const handle =
      normalizeHandle(account.handle) ??
      normalizeHandle(account.username) ??
      normalizeHandle(account.name)

    const providerSubject =
      account.provider_subject?.trim() ||
      account.subject?.trim() ||
      account.user_id?.trim() ||
      account.id?.trim() ||
      ""

    if (!handle || providerSubject.length === 0) {
      continue
    }

    return {
      handle,
      profileUrl: account.profile_url?.trim() || `https://x.com/${handle}`,
      providerSubject,
    }
  }

  return null
}

export const XLinkFlow: Hook = {
  async mounted() {
    const button = this.el.querySelector<HTMLElement>("[data-x-link-action='connect']")
    const appId = this.el.dataset.privyAppId || ""
    const startEndpoint = this.el.dataset.startEndpoint || ""
    const callbackEndpoint = this.el.dataset.callbackEndpoint || ""
    const redirectPath = this.el.dataset.redirectPath || ""
    const initialAgentId = this.el.dataset.agentId || ""

    if (!button || appId.trim() === "" || startEndpoint === "" || callbackEndpoint === "") return

    const csrfToken =
      document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() || ""

    const privy = new Privy({ appId, storage: new LocalStorage() })

    const startConnect = async () => {
      this.pushEvent("x_link_started", {})

      const response = await fetch(startEndpoint, {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          ...csrfHeaders(csrfToken),
        },
        credentials: "same-origin",
        body: JSON.stringify({ agent_id: this.el.dataset.agentId || initialAgentId }),
      })

      const payload = (await response.json()) as
        | { ok?: boolean; provider?: string; agent_id?: string; redirect_path?: string; error?: { message?: string } }
        | undefined

      if (!response.ok || !payload?.ok || !payload.provider || !payload.agent_id) {
        this.pushEvent("x_link_error", {
          message: payload?.error?.message || "The X connection could not be started.",
        })
        return
      }

      const redirectURI = `${window.location.origin}${payload.redirect_path || redirectPath}`
      const result = await privy.auth.oauth.generateURL(payload.provider, redirectURI)

      window.localStorage.setItem(PROVIDER_STORAGE_KEY, payload.provider)
      window.localStorage.setItem(AGENT_STORAGE_KEY, payload.agent_id)
      window.location.assign(result.url)
    }

    const completeCallbackIfPresent = async () => {
      const provider = window.localStorage.getItem(PROVIDER_STORAGE_KEY)
      const agentId = window.localStorage.getItem(AGENT_STORAGE_KEY) || initialAgentId
      const url = new URL(window.location.href)
      const code = url.searchParams.get("code")
      const oauthState = url.searchParams.get("state")

      if (!provider || !agentId || !code || !oauthState) return

      try {
        await privy.auth.oauth.loginWithCode(code, oauthState, provider)
        const result = await privy.user.get()
        const user = (result?.user ?? null) as PrivyUser
        const account = findXAccount(user)

        if (!account) {
          throw new Error("The returned Privy session did not include a usable X account.")
        }

        const response = await fetch(callbackEndpoint, {
          method: "POST",
          headers: {
            accept: "application/json",
            "content-type": "application/json",
            ...csrfHeaders(csrfToken),
          },
          credentials: "same-origin",
          body: JSON.stringify({
            agent_id: agentId,
            handle: account.handle,
            profile_url: account.profileUrl,
            provider_subject: account.providerSubject,
          }),
        })

        const payload = (await response.json()) as
          | { ok?: boolean; error?: { message?: string } }
          | undefined

        if (!response.ok || !payload?.ok) {
          throw new Error(payload?.error?.message || "The X connection could not be saved.")
        }

        this.pushEvent("x_link_completed", { agent_id: agentId })
      } catch (error) {
        const message =
          error instanceof Error ? error.message : "The X connection flow did not complete."
        this.pushEvent("x_link_error", { message })
      } finally {
        window.localStorage.removeItem(PROVIDER_STORAGE_KEY)
        window.localStorage.removeItem(AGENT_STORAGE_KEY)
        url.searchParams.delete("code")
        url.searchParams.delete("state")
        window.history.replaceState({}, "", url.toString())
      }
    }

    button.addEventListener("click", () => void startConnect())

    await privy.initialize()
    await completeCallbackIfPresent()
  },
}
