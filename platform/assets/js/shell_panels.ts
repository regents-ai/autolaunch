// The app shell's Buy Credits window, which the browser alone opens and closes,
// as the template's shell does. Its state is its own `open`, which LiveView leaves
// alone. The account menu and the Regents Products menu are popovers the browser
// opens and closes itself; only following a link inside one, and opening Buy
// Credits from the account menu's balance row, are ours.

/**
 * Brings `target`, what an address's #fragment names, into view. When it holds a
 * choice, such as the pairing box's agents, focus goes to the chosen one, or the
 * first, so the keyboard starts there. Returns whether it holds one.
 */
export function arriveAt(target: HTMLElement) {
  target.scrollIntoView()
  const choices = [...target.querySelectorAll<HTMLInputElement>("input[type=radio]")]
  const choice = choices.find(radio => radio.checked) ?? choices[0]
  // Next frame: following the link, and LiveView's patch, each move focus first.
  if (choice) requestAnimationFrame(() => choice.focus({preventScroll: true}))
  return choice !== undefined
}

/** Wires the Buy Credits window and the menus' links inside `scope`. Returns `cleanup`. */
export function installShellPanels(scope: Document | HTMLElement = document) {
  const credits = () => scope.querySelector<HTMLDialogElement>("#shell-credits")

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

    // The top bar's balance, and the account menu's balance row on the narrowest
    // phones, open the one window. The menu closes first, so focus goes back to
    // the account button and returns there when the window closes.
    const creditsOpener = target.closest<HTMLElement>("[data-credits-open]")
    if (creditsOpener) {
      creditsOpener.closest<HTMLElement>("[popover]")?.hidePopover()
      return openCredits()
    }
    if (target.closest("[data-credits-close]")) return closeCredits()
    // A press on a window's own backdrop lands on the dialog itself.
    if (target === credits()) return closeCredits()

    // A page change keeps an open menu open, so a link followed from one closes
    // it. A link to a #fragment of this page changes nothing LiveView sees when
    // the address already shows it, so what it names comes into view here, every
    // press.
    const link = target.closest<HTMLAnchorElement>("a[href]")
    if (!link) return
    link.closest<HTMLElement>("[popover]")?.hidePopover()
    const named = link.hash && link.pathname === window.location.pathname
      ? document.getElementById(decodeURIComponent(link.hash.slice(1)))
      : null
    if (named) arriveAt(named)
  }

  scope.addEventListener("click", onClick)

  return {
    cleanup: () => scope.removeEventListener("click", onClick),
  }
}
