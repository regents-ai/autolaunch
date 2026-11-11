// The app shell's pairing window, which the browser alone opens and closes, as
// the template's shell does. Its state is its own `open`,
// which LiveView leaves alone. The account menu and the Regents Products menu are
// popovers the browser opens and closes itself; only following a link inside one,
// and opening a window from the account menu, are ours. So is Escape's order: the
// last open section a person can see goes first, then the window it sits in.

/**
 * Brings `target`, what an address's #fragment names, into view. When it holds a
 * choice, such as the bid form's Pay with, focus goes to the chosen one, or the
 * first, so the keyboard starts there.
 */
export function arriveAt(target: HTMLElement) {
  target.scrollIntoView()
  const choices = [...target.querySelectorAll<HTMLInputElement>("input[type=radio]")]
  const choice = choices.find(radio => radio.checked) ?? choices[0]
  // Next frame: following the link, and LiveView's patch, each move focus first.
  if (choice) requestAnimationFrame(() => choice.focus({preventScroll: true}))
}

/** Wires the pairing window and the menus' links inside `scope`. Returns `cleanup`. */
export function installShellPanels(scope: Document | HTMLElement = document) {
  const pairing = () => scope.querySelector<HTMLDialogElement>("#shell-pairing")

  // The window opens on the list of agents while none is chosen, with the keyboard
  // on the dropdown.
  const openPairing = () => {
    const dialog = pairing()
    if (!dialog || dialog.open) return
    dialog.showModal()
    const pick = dialog.querySelector<HTMLDetailsElement>("details.rg-pill-select")
    if (!pick) return
    if (!pick.querySelector("input:checked")) pick.open = true
    pick.querySelector<HTMLElement>(":scope > summary")?.focus()
  }

  const closePairing = () => pairing()?.close()

  const onClick = (event: Event) => {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return

    // Pair New Agent, in the account menu and on the Agents page, opens the one
    // pairing window. The menu closes first, so focus goes back to the account
    // button and returns there when the window closes.
    const pairOpener = target.closest<HTMLElement>("[data-pair-open]")
    if (pairOpener) {
      pairOpener.closest<HTMLElement>("[popover]")?.hidePopover()
      return openPairing()
    }
    if (target.closest("[data-pair-close]")) return closePairing()
    // A press on the window's own backdrop lands on the dialog itself.
    if (target === pairing()) return closePairing()

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

  // An open account or Regents Products menu takes Escape itself, and so does an
  // open dropdown (pill_select.mjs) or the phone menu. Otherwise Escape closes the
  // last open section a person can see, inside the open window when one is open; a
  // window with none open inside closes itself.
  const onKeydown = (event: Event) => {
    if (!(event instanceof KeyboardEvent) || event.key !== "Escape" || event.defaultPrevented) return
    if (scope.querySelector(":popover-open")) return
    const layer = [...scope.querySelectorAll<HTMLDialogElement>("dialog:modal")].at(-1) ?? scope
    const openDetails = [...layer.querySelectorAll<HTMLDetailsElement>("details[open]")]
      .filter(details => details.checkVisibility())
      .at(-1)
    if (!openDetails) return
    openDetails.removeAttribute("open")
    openDetails.querySelector<HTMLElement>(":scope > summary")?.focus()
    event.preventDefault()
  }

  scope.addEventListener("click", onClick)
  scope.addEventListener("keydown", onKeydown)

  return {
    cleanup: () => {
      scope.removeEventListener("click", onClick)
      scope.removeEventListener("keydown", onKeydown)
    },
  }
}
