import {mountProfile} from "../vendor/regent_ui/profile.mjs"
import {installProfileTools} from "../vendor/regent_identity/profile_tools.mjs"
import type {ProfileAction} from "../vendor/regent_identity/profile_client.mjs"
import type {AccountRequest, IdentityRequest} from "./auth_lazy"

export function installSharedProfile(doc: Document, adapter: {
  profile: ProfileAction
  request: (request: AccountRequest) => Promise<void>
  identity: (request: IdentityRequest) => Promise<void>
}): () => void {
  const win = doc.defaultView
  if (!win) return () => {}
  const profile: ProfileAction = async (...args) => {
    try { return await adapter.profile(...args) }
    catch { return {ok: false, status: null, error: {code: "profile_unavailable", outcome_unknown: args[0] !== "get"}} }
  }
  const stopTools = installProfileTools(profile, win)
  const root = doc.querySelector<HTMLElement>("[data-regent-profile]")
  const stopPanel = root ? mountProfile(root, {
    profile,
    signIn: () => adapter.request("sign-in"),
    async linkX() {
      await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => finish(false), 120_000)
        const changed = (event: Event) => finish((event as CustomEvent).detail?.ok === true)
        const finish = (ok: boolean) => {
          clearTimeout(timeout)
          win.removeEventListener("regent:profile-link", changed)
          if (ok) resolve()
          else reject(new Error("profile_link_failed"))
        }
        win.addEventListener("regent:profile-link", changed)
        void adapter.identity({action: "link", provider: "x"}).catch(() => finish(false))
      })
    },
    onIdentityChange(callback) {
      win.addEventListener("regent:profile-identity", callback)
      win.addEventListener("regent:profile-link", callback)
      return () => {
        win.removeEventListener("regent:profile-identity", callback)
        win.removeEventListener("regent:profile-link", callback)
      }
    },
  }) : () => {}
  return () => { stopPanel(); stopTools() }
}
