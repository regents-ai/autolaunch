import {closeDialog} from "../motion/panels"

type SiteSearchHook = {
  el: HTMLElement
  pushEvent(event: string, payload: Record<string, never>): void
  mark?: (index: number, scroll?: boolean) => void
  active: number
  shown: string
  cleanup?: () => void
}

// Fields where "/" is typed rather than opening the search.
const TYPING = "input, textarea, select, [contenteditable]:not([contenteditable='false'])"

const options = (list: HTMLElement) => Array.from(list.querySelectorAll<HTMLElement>("[role='option']"))
const shownIds = (list: HTMLElement) => options(list).map(option => option.id).join(" ")

// The search window (`AutolaunchWeb.SearchLive`): the header's button, ⌘K or
// Ctrl K, or "/" outside a field opens it; ↑ and ↓ move the highlighted row,
// Enter opens it, Escape or a click outside closes the window and focus goes
// back to where it was, or to the header's button. The server reads and
// renders every row; this only moves the highlight.
export const SiteSearch = {
  mounted(this: SiteSearchHook) {
    const dialog = this.el.querySelector<HTMLDialogElement>("dialog")!
    const input = dialog.querySelector<HTMLInputElement>("[role='combobox']")!
    const list = dialog.querySelector<HTMLElement>("[role='listbox']")!
    const mac = /Mac|iPhone|iPad/.test(navigator.platform)
    let opener: HTMLElement | null = null

    for (const key of document.querySelectorAll("[data-search-shortcut]")) key.textContent = mac ? "⌘ K" : "Ctrl K"

    const mark = (index: number, scroll = false) => {
      const all = options(list)
      this.active = all.length === 0 ? -1 : (index + all.length) % all.length
      all.forEach((option, at) => option.setAttribute("aria-selected", String(at === this.active)))
      const current = all[this.active]
      if (current === undefined) {
        input.removeAttribute("aria-activedescendant")
        return
      }
      input.setAttribute("aria-activedescendant", current.id)
      if (scroll) current.scrollIntoView({block: "nearest"})
    }

    const open = () => {
      if (!dialog.open) {
        const focused = document.activeElement
        opener = focused instanceof HTMLElement && focused !== document.body ? focused : null
        dialog.showModal()
        this.pushEvent("open", {})
      }
      input.focus()
      input.select()
      mark(0)
    }

    const onDocumentClick = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest("[data-search-open]")) open()
    }
    const onDocumentKey = (event: KeyboardEvent) => {
      if (event.isComposing || event.altKey) return
      const shortcut = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k"
      const slash = event.key === "/" && !event.metaKey && !event.ctrlKey &&
        !(event.target instanceof Element && event.target.closest(TYPING))
      if (!shortcut && !slash) return
      event.preventDefault()
      open()
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.isComposing) return
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault()
        mark(this.active + (event.key === "ArrowDown" ? 1 : -1), true)
      } else if (event.key === "Enter") {
        event.preventDefault()
        options(list)[this.active]?.click()
      }
    }
    const onPointer = (event: PointerEvent) => {
      const option = event.target instanceof Element ? event.target.closest<HTMLElement>("[role='option']") : null
      if (option !== null) mark(options(list).indexOf(option))
    }
    const onClick = (event: MouseEvent) => {
      const target = event.target
      if (!(target instanceof Element)) return
      if (target.closest("[data-search-close]")) {
        closeDialog(dialog)
      } else if (target.closest("[role='option']")) {
        // The chosen page opens in this tab; the window gets out of its way.
        if (event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey) dialog.close()
      } else if (target === dialog) {
        const box = dialog.getBoundingClientRect()
        if (event.clientX < box.left || event.clientX > box.right ||
            event.clientY < box.top || event.clientY > box.bottom) closeDialog(dialog)
      }
    }
    const onCancel = (event: Event) => {
      event.preventDefault()
      closeDialog(dialog)
    }
    const onClose = () => {
      const back = opener?.isConnected ? opener : document.querySelector<HTMLElement>("[data-search-open]")
      opener = null
      back?.focus({preventScroll: true})
    }
    const onSubmit = (event: SubmitEvent) => event.preventDefault()

    document.addEventListener("click", onDocumentClick)
    document.addEventListener("keydown", onDocumentKey)
    input.addEventListener("keydown", onKey)
    input.form!.addEventListener("submit", onSubmit)
    list.addEventListener("pointermove", onPointer)
    dialog.addEventListener("click", onClick)
    dialog.addEventListener("cancel", onCancel)
    dialog.addEventListener("close", onClose)

    this.mark = mark
    this.active = -1
    this.shown = shownIds(list)
    this.cleanup = () => {
      document.removeEventListener("click", onDocumentClick)
      document.removeEventListener("keydown", onDocumentKey)
    }
  },

  // New rows start the highlight on the first one; the same rows, patched
  // again, keep it where it was.
  updated(this: SiteSearchHook) {
    const list = this.el.querySelector<HTMLElement>("[role='listbox']")!
    const shown = shownIds(list)
    this.mark?.(shown === this.shown ? Math.max(this.active, 0) : 0)
    this.shown = shown
  },

  destroyed(this: SiteSearchHook) { this.cleanup?.() },
}
