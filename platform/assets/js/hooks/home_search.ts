type HomeSearchHook = {
  el: HTMLElement
  cleanup?: () => void
  sync?: () => void
  query?: string
}

// Shared market search; remove document listeners on LiveView navigation.
export const HomeSearch = {
  mounted(this: HomeSearchHook) {
    const input = this.el.querySelector<HTMLInputElement>("#home-search-q")!
    const form = input.form!
    const clear = this.el.querySelector<HTMLButtonElement>("[data-clear-search]")!
    const shortcut = this.el.querySelector<HTMLElement>("kbd")!
    shortcut.textContent = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘ K" : "Ctrl K"
    const sync = () => { clear.hidden = input.value.length === 0 }
    const keydown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "k") {
        event.preventDefault()
        input.focus()
        input.select()
      }
    }
    const reset = () => {
      input.value = ""
      sync()
      input.focus()
      form.requestSubmit()
    }
    document.addEventListener("keydown", keydown)
    input.addEventListener("input", sync)
    clear.addEventListener("click", reset)
    this.query = this.el.dataset.query ?? ""
    this.sync = sync
    this.cleanup = () => {
      document.removeEventListener("keydown", keydown)
      input.removeEventListener("input", sync)
      clear.removeEventListener("click", reset)
    }
    sync()
  },
  updated(this: HomeSearchHook) {
    const query = this.el.dataset.query ?? ""
    // LiveView deliberately preserves focused input values. On Back/Forward,
    // adopt the server query, but don't erase unsent typing on unrelated patches.
    if (query !== this.query) {
      this.el.querySelector<HTMLInputElement>("#home-search-q")!.value = query
      this.query = query
    }
    this.sync?.()
  },
  destroyed(this: HomeSearchHook) { this.cleanup?.() },
}

export function installStaticMarketSearch(): void {
  const el = document.getElementById("home-top")
  if (!el || el.closest("[data-phx-main]")) return
  const instance: HomeSearchHook = {el}
  HomeSearch.mounted.call(instance)
  window.addEventListener("pagehide", event => {
    if (!event.persisted) HomeSearch.destroyed.call(instance)
  })
}
