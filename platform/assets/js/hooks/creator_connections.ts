import type {Hook} from "../hook_composition"
type CreatorHook = Hook & {
  el: HTMLElement
  linkingGithub?: boolean
  onCreatorClick?: (event: Event) => void
  onCreatorIdentity?: (event: Event) => void
}

export const CreatorConnections = {
  mounted(this: CreatorHook) {
    const root = this.el as HTMLElement
    this.onCreatorClick = (event: Event) => {
      if ((event.target as Element)?.closest("[data-connect-github]")) {
        this.linkingGithub = true
        document.dispatchEvent(new CustomEvent("autolaunch:identity-request", {
          detail: {action: "link", provider: "github"},
        }))
      }
    }
    this.onCreatorIdentity = (event: Event) => {
      if (!this.linkingGithub) return
      this.linkingGithub = false
      const detail = (event as CustomEvent<{error: string | null}>).detail
      if (detail && !detail.error) window.location.reload()
      else {
        const status = root.querySelector("[data-creator-connection-status]")
        if (status) status.textContent = "GitHub could not be connected. Try again."
      }
    }
    root.addEventListener("click", this.onCreatorClick)
    window.addEventListener("autolaunch:identity-state", this.onCreatorIdentity)
  },
  destroyed(this: CreatorHook) {
    if (this.onCreatorClick) this.el.removeEventListener("click", this.onCreatorClick)
    if (this.onCreatorIdentity) window.removeEventListener("autolaunch:identity-state", this.onCreatorIdentity)
  },
}
