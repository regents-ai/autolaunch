// The menu button that folds the site links away on narrow screens.
export function installShellMenu(): void {
  document.addEventListener("click", (event) => {
    const toggle =
      event.target instanceof Element
        ? event.target.closest<HTMLElement>("[data-shell-menu-toggle]")
        : null
    if (!toggle) return
    const open = toggle.getAttribute("aria-expanded") === "true"
    toggle.setAttribute("aria-expanded", open ? "false" : "true")
  })
}
