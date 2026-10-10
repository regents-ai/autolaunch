import type {ProfileAction} from "../vendor/regent_identity/profile_client.mjs"

// Owner profile UI remains available. Its cookie authority is never registered as an agent tool.
export function installSharedProfile(_doc: Document, _adapter: {profile: ProfileAction}): () => void {
  return () => {}
}
