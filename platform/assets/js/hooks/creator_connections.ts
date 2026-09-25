import type {Hook} from "../hook_composition"

type GithubStep = "connect" | "disconnect"

type CreatorHook = Hook & {
  el: HTMLElement
  githubStep?: GithubStep
  onCreatorClick?: (event: Event) => void
  onCreatorIdentity?: (event: Event) => void
}

const request = (detail: {action: "link" | "unlink", provider: "github", subject?: string}) =>
  document.dispatchEvent(new CustomEvent("autolaunch:identity-request", {detail}))

const failure: Record<GithubStep, string> = {
  connect: "GitHub could not be connected. Try again.",
  disconnect: "GitHub could not be disconnected. Try again.",
}

export const CreatorConnections = {
  mounted(this: CreatorHook) {
    const root = this.el as HTMLElement
    this.onCreatorClick = (event: Event) => {
      const button = (event.target as Element)?.closest<HTMLElement>("[data-connect-github], [data-disconnect-github]")
      if (!button) return
      if (button.hasAttribute("data-disconnect-github")) {
        this.githubStep = "disconnect"
        request({action: "unlink", provider: "github", subject: button.dataset.githubSubject})
      } else {
        this.githubStep = "connect"
        request({action: "link", provider: "github"})
      }
    }
    this.onCreatorIdentity = (event: Event) => {
      const step = this.githubStep
      if (!step) return
      const detail = (event as CustomEvent<{error: string | null}>).detail
      if (!detail || detail.error) {
        this.githubStep = undefined
        const status = root.querySelector("[data-creator-connection-status]")
        if (status) status.textContent = failure[step]
      } else {
        this.githubStep = undefined
        window.location.reload()
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
