import {installProfileTools} from "../vendor/regent_identity/profile_tools.mjs"
import type {ProfileAction} from "../vendor/regent_identity/profile_client.mjs"

export function installSharedProfile(doc: Document, adapter: {profile: ProfileAction}): () => void {
  const win = doc.defaultView
  if (!win) return () => {}
  const profile: ProfileAction = async (...args) => {
    try { return await adapter.profile(...args) }
    catch { return {ok: false, status: null, error: {code: "profile_unavailable", outcome_unknown: args[0] !== "get"}} }
  }
  return installProfileTools(profile, win)
}
