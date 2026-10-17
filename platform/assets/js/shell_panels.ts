// The side panel and the Buy Credits window, which the browser alone opens and
// closes, as the template's shell does. The side panel's
// state lives on <html data-aside>, which the server first draws from the cookie
// written here (AutolaunchWeb.Plugs.Panels), so LiveView never patches it away;
// each window's is its own `open`, which LiveView leaves alone. Where the side
// bar covers the page, it opens only when the person opens it on that page
// (<html data-aside-here>), never from the remembered state.

const yearInSeconds = 60 * 60 * 24 * 365
const cookie = "autolaunch_aside"

// The server's value, closed, is the default; only open is kept.
function remember(value: string) {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  const age = value === "open" ? yearInSeconds : 0
  document.cookie = `${cookie}=${value}; Path=/; Max-Age=${age}; SameSite=Lax${secure}`
}

const root = () => document.documentElement
// Below a wide screen the side panel covers the page's edge; on a wide one it
// sits beside the page.
const covering = window.matchMedia("(max-width: 63.99rem)")
const asideOpen = () =>
  root().dataset.aside === "open" && (!covering.matches || root().dataset.asideHere !== undefined)

/** Wires the side panel and the Buy Credits window inside `scope`. Returns `sync`, to run after every page update, and `cleanup`. */
export function installShellPanels(scope: Document | HTMLElement = document) {
  const aside = () => scope.querySelector<HTMLElement>("#shell-aside")
  const asideButton = () => scope.querySelector<HTMLButtonElement>("#shell-aside-button")
  const credits = () => scope.querySelector<HTMLDialogElement>("#shell-credits")

  // The side panel's own button and the account name in the header both open it.
  const sync = () => {
    scope.querySelectorAll("[data-aside-toggle]").forEach(toggle =>
      toggle.setAttribute("aria-expanded", String(asideOpen())))
  }

  const setAside = (open: boolean) => {
    const value = open ? "open" : "closed"
    root().dataset.aside = value
    if (open) root().dataset.asideHere = ""
    else delete root().dataset.asideHere
    remember(value)
    sync()

    // Opened, focus moves into it, so Escape closes it and returns focus to the
    // button that opened it.
    if (open) aside()?.focus()
  }

  // Opening Buy Credits reads the wallet's funds again, so Buy is held back
  // only by what the chain says now.
  const openCredits = () => {
    const dialog = credits()
    if (!dialog || dialog.open) return
    dialog.showModal()
    dialog
      .querySelectorAll("[data-refresh-funds]")
      .forEach(panel => panel.dispatchEvent(new CustomEvent("autolaunch:refresh-funds")))
  }

  const closeCredits = () => credits()?.close()

  const onClick = (event: Event) => {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return

    if (target.closest("[data-aside-toggle]")) return setAside(!asideOpen())
    if (target.closest("[data-aside-close]")) {
      setAside(false)
      return asideButton()?.focus()
    }
    // The top bar's balance, and the side panel's on a phone, open the one window.
    if (target.closest("[data-credits-open]")) return openCredits()
    if (target.closest("[data-credits-close]")) return closeCredits()
    // A press on a window's own backdrop lands on the dialog itself.
    if (target === credits()) return closeCredits()
    // Where the side bar covers the page, a page link inside it closes it.
    if (covering.matches && target.closest("#shell-aside a")) setAside(false)
  }

  const onKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape" && asideOpen() && aside()?.contains(document.activeElement)) {
      event.preventDefault()
      setAside(false)
      asideButton()?.focus()
    }
  }

  scope.addEventListener("click", onClick)
  document.addEventListener("keydown", onKeydown)
  covering.addEventListener("change", sync)

  sync()

  return {
    sync,
    cleanup: () => {
      scope.removeEventListener("click", onClick)
      document.removeEventListener("keydown", onKeydown)
      covering.removeEventListener("change", sync)
    },
  }
}
