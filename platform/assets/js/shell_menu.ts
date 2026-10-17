// The phone menu: the template's drawer (ash-template `shellBehavior` in
// platform/assets/js/app.ts). The top bar's Menu button opens it; its Close
// navigation bar, the dimmed page beside it, Escape, a link inside it and a
// move to another page close it, and focus goes back to the Menu button. While
// it is open, Tab stays inside it and the page behind is inert.
//
// Its state lives on <html data-menu>, outside what LiveView draws, so a page
// update never shuts it; the page behind carries `inert`, which LiveView keeps
// (`JS.ignore_attributes`). The server always draws it closed.

const phone = window.matchMedia("(max-width: 47.99rem)")
const focusable =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

export function installShellMenu() {
  const root = document.documentElement
  const menuButton = () => document.querySelector<HTMLButtonElement>("#mobile-menu-button")
  const drawer = () => document.querySelector<HTMLElement>("#shell-drawer")
  const menuOpen = () => root.dataset.menu === "open"
  const menuFocusables = () =>
    Array.from(drawer()?.querySelectorAll<HTMLElement>(focusable) ?? []).filter(
      element => !element.hidden && !element.inert,
    )

  // The button and the page behind follow the state, on every page drawn.
  const sync = () => {
    const open = menuOpen()
    menuButton()?.setAttribute("aria-expanded", String(open))
    document.querySelectorAll<HTMLElement>("[data-shell-behind-menu]").forEach(behind => {
      behind.inert = open
    })
  }

  const setMenu = (open: boolean, restoreFocus: boolean) => {
    if (open) root.dataset.menu = "open"
    else delete root.dataset.menu
    sync()

    if (open) {
      const [first] = menuFocusables()
      ;(first ?? drawer())?.focus()
    } else if (restoreFocus) {
      menuButton()?.focus()
    }
  }

  const onClick = (event: MouseEvent) => {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return

    if (target.closest("#mobile-menu-button")) return setMenu(!menuOpen(), false)
    if (target.closest("[data-shell-menu-scrim], [data-shell-menu-close]")) return setMenu(false, true)
    if (menuOpen() && target.closest("#shell-drawer a")) return setMenu(false, true)
    // The top bar stays usable beside the menu; anything else pressed there
    // (search, Regents Products, the account) takes over from it.
    if (menuOpen() && target.closest("#home-top")) setMenu(false, false)
  }

  const onKeydown = (event: KeyboardEvent) => {
    // A window opened from the menu, such as search, handles its own keys.
    if (!menuOpen() || document.querySelector("dialog:modal")) return

    if (event.key === "Escape") {
      event.preventDefault()
      setMenu(false, true)
      return
    }

    if (event.key !== "Tab") return
    const focusables = menuFocusables()
    const first = focusables.at(0)
    const last = focusables.at(-1)
    const currentDrawer = drawer()

    if (!first || !last) {
      event.preventDefault()
      currentDrawer?.focus()
    } else if (!currentDrawer?.contains(document.activeElement)) {
      event.preventDefault()
      ;(event.shiftKey ? last : first).focus()
    } else if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  // Moving to another page, coming back to one the browser kept, or widening
  // past a phone, where there is no drawer, closes it.
  const closeQuietly = () => {
    if (menuOpen()) setMenu(false, false)
  }

  document.addEventListener("click", onClick)
  document.addEventListener("keydown", onKeydown)
  window.addEventListener("phx:page-loading-start", closeQuietly)
  window.addEventListener("phx:page-loading-stop", sync)
  window.addEventListener("pageshow", closeQuietly)
  phone.addEventListener("change", closeQuietly)
  sync()
}
