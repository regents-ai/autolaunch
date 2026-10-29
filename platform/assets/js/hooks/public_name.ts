import {mountProfile} from "../../vendor/regent_ui/profile.mjs"
import {openProfile} from "../auth_lazy"
import type {Hook} from "../hook_composition"

type PublicNameHook = {
  el: HTMLElement
  pushEvent(event: string, payload: unknown): void
  stop?: () => void
}

// Saves the person's Public Display Name with their sign-in's own proof, then
// asks the page to read the account again so every place showing the name
// shows the new one.
export const PublicName: Hook = {
  mounted(this: PublicNameHook) {
    this.stop = mountProfile(this.el, {
      openProfile: () => openProfile(document),
      onSaved: () => this.pushEvent("public_name_saved", {}),
    })
  },

  destroyed(this: PublicNameHook) {
    this.stop?.()
  },
}
