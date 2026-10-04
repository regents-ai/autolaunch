import {closeDialog} from "../motion/panels"

type SearchDialogHook = {
  el: HTMLDialogElement
  pushEvent(event: string, payload: object): void
  cleanup?: () => void
  pick?: () => void
}

// The reader's recent searches stay in this browser only.
const RECENT_KEY = "autolaunch:recent-searches"
const RECENT_LIMIT = 5

function readRecent(): string[] {
  try {
    return JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]")
  } catch {
    return []
  }
}

function writeRecent(recent: string[]): void {
  try { localStorage.setItem(RECENT_KEY, JSON.stringify(recent)) } catch { /* searching still works */ }
}

const collapse = (value: string) => value.split(/\s+/).filter(Boolean).join(" ")

// The search window: the header's search bar and ⌘ K open it, and the page
// changes only when a result is picked, by click or by Enter.
export const SearchDialog = {
  mounted(this: SearchDialogHook) {
    const dialog = this.el
    const input = () => dialog.querySelector<HTMLInputElement>("#search-dialog-q")!
    const items = () => [...dialog.querySelectorAll<HTMLAnchorElement>("a[data-search-result], a[data-search-all]")]
    const shown = () => dialog.dataset.query === collapse(input().value)
    let opener: Element | null = null
    // Enter pressed before the results for what was typed arrived: the first of them opens when they do.
    let waiting = false

    for (const key of document.querySelectorAll("[data-open-search] kbd")) {
      key.textContent = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘ K" : "Ctrl K"
    }

    const open = () => {
      if (dialog.open) return
      opener = document.activeElement
      dialog.showModal()
      input().focus()
      input().select()
      this.pushEvent("open", {recent: readRecent()})
    }
    const remember = () => {
      const term = collapse(input().value)
      if (term === "") return
      writeRecent([term, ...readRecent().filter(other => other !== term)].slice(0, RECENT_LIMIT))
    }
    const pick = () => {
      waiting = false
      items()[0]?.click()
    }
    const onDocumentClick = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest("[data-open-search]")) open()
    }
    const onDocumentKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "k") {
        event.preventDefault()
        open()
      }
    }
    const onClick = (event: MouseEvent) => {
      const target = event.target
      if (!(target instanceof Element)) return
      if (target.closest("[data-close-search]")) {
        closeDialog(dialog)
      } else if (target.closest("[data-clear-recent]")) {
        writeRecent([])
        this.pushEvent("recent", {recent: []})
      } else if (target.closest("a[data-search-result], a[data-search-all]")) {
        remember()
        dialog.close()
      } else if (target === dialog) {
        const box = dialog.getBoundingClientRect()
        if (event.clientX < box.left || event.clientX > box.right ||
            event.clientY < box.top || event.clientY > box.bottom) closeDialog(dialog)
      }
    }
    // Up and Down move between the search field and the results.
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return
      const list = items()
      const at = list.indexOf(document.activeElement as HTMLAnchorElement)
      event.preventDefault()
      if (event.key === "ArrowDown") list[Math.min(at + 1, list.length - 1)]?.focus()
      else if (at <= 0) input().focus()
      else list[at - 1].focus()
    }
    const onSubmit = (event: SubmitEvent) => {
      event.preventDefault()
      if (collapse(input().value) === "") return
      if (shown()) {
        pick()
      } else {
        // Enter drops the field's pending search, so it is sent here.
        waiting = true
        this.pushEvent("search", {q: input().value})
      }
    }
    const onInput = () => { waiting = false }
    const onCancel = (event: Event) => {
      event.preventDefault()
      closeDialog(dialog)
    }
    const onClose = () => {
      waiting = false
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus({preventScroll: true})
    }

    document.addEventListener("click", onDocumentClick)
    document.addEventListener("keydown", onDocumentKey)
    dialog.addEventListener("click", onClick)
    dialog.addEventListener("keydown", onKey)
    dialog.addEventListener("submit", onSubmit)
    dialog.addEventListener("input", onInput)
    dialog.addEventListener("cancel", onCancel)
    dialog.addEventListener("close", onClose)
    this.pick = () => { if (waiting && shown()) pick() }
    this.cleanup = () => {
      document.removeEventListener("click", onDocumentClick)
      document.removeEventListener("keydown", onDocumentKey)
      dialog.removeEventListener("click", onClick)
      dialog.removeEventListener("keydown", onKey)
      dialog.removeEventListener("submit", onSubmit)
      dialog.removeEventListener("input", onInput)
      dialog.removeEventListener("cancel", onCancel)
      dialog.removeEventListener("close", onClose)
      if (dialog.open) dialog.close()
    }
  },
  updated(this: SearchDialogHook) { this.pick?.() },
  destroyed(this: SearchDialogHook) { this.cleanup?.() },
}
