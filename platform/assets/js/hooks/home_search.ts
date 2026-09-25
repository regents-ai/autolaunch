type HomeSearchHook = {
  el: HTMLElement
  cleanup?: () => void
  sync?: () => void
  query?: string
}

// Typing on another page opens the home results; this carries what was typed,
// trailing space included, so the field there picks up where it left off.
const TYPED_KEY = "autolaunch:search-typed"
const TYPE_PAUSE_MS = 300

function takeTyped(): string | null {
  try {
    const typed = sessionStorage.getItem(TYPED_KEY)
    sessionStorage.removeItem(TYPED_KEY)
    return typed
  } catch {
    return null
  }
}

function keepTyped(value: string): void {
  try { sessionStorage.setItem(TYPED_KEY, value) } catch { /* the field still searches */ }
}

const collapse = (value: string) => value.split(/\s+/).filter(Boolean).join(" ")

// Shared market search; remove document listeners on LiveView navigation.
export const HomeSearch = {
  mounted(this: HomeSearchHook) {
    const input = this.el.querySelector<HTMLInputElement>("#home-search-q")!
    const form = input.form!
    const clear = this.el.querySelector<HTMLButtonElement>("[data-clear-search]")!
    const shortcut = this.el.querySelector<HTMLElement>("kbd")!
    shortcut.textContent = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘ K" : "Ctrl K"
    const sync = () => { clear.hidden = input.value.length === 0 }
    const onHome = () => this.el.dataset.home === "true"
    let pause: number | undefined
    // Off the home page the field searches after a pause in typing too, by opening the results.
    const typed = () => {
      if (onHome()) return
      window.clearTimeout(pause)
      pause = window.setTimeout(() => {
        if (input.value.trim() === "") return
        keepTyped(input.value)
        form.requestSubmit()
      }, TYPE_PAUSE_MS)
    }
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
    input.addEventListener("input", typed)
    clear.addEventListener("click", reset)
    this.query = this.el.dataset.query ?? ""
    this.sync = sync
    this.cleanup = () => {
      document.removeEventListener("keydown", keydown)
      input.removeEventListener("input", sync)
      input.removeEventListener("input", typed)
      clear.removeEventListener("click", reset)
      window.clearTimeout(pause)
    }
    const carried = takeTyped()
    if (onHome() && carried !== null) {
      if (collapse(input.value) === collapse(carried)) input.value = carried
      input.focus()
      input.setSelectionRange(input.value.length, input.value.length)
    }
    sync()
  },
  updated(this: HomeSearchHook) {
    const query = this.el.dataset.query ?? ""
    const input = this.el.querySelector<HTMLInputElement>("#home-search-q")!
    // On Back/Forward, adopt the server query. While the field has focus the
    // results follow its typing, so leave what is typed (spaces included) alone.
    if (query !== this.query && document.activeElement !== input) input.value = query
    this.query = query
    this.sync?.()
  },
  destroyed(this: HomeSearchHook) { this.cleanup?.() },
}

export function installStaticMarketSearch(): void {
  const el = document.getElementById("home-search")
  if (!el || el.closest("[data-phx-main]")) return
  const instance: HomeSearchHook = {el}
  HomeSearch.mounted.call(instance)
  window.addEventListener("pagehide", event => {
    if (!event.persisted) HomeSearch.destroyed.call(instance)
  })
}
