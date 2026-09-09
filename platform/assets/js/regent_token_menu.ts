// Delegation survives LiveView patches and also serves ordinary HTML pages.
// Native details/summary retains click, touch and keyboard operation without JS.
export function installRegentTokenMenu(): void {
  const selector = "details[data-regent-token-menu]";
  const contains = (menu: HTMLDetailsElement, target: EventTarget | null) =>
    target instanceof Node && menu.contains(target);
  const menuFor = (target: EventTarget | null) =>
    target instanceof Element ? target.closest<HTMLDetailsElement>(selector) : null;

  document.addEventListener("pointerover", (event) => {
    const menu = menuFor(event.target);
    if (event.pointerType === "mouse" && menu && !contains(menu, event.relatedTarget)) {
      menu.open = true;
    }
  });
  document.addEventListener("pointerout", (event) => {
    const menu = menuFor(event.target);
    if (event.pointerType === "mouse" && menu && !contains(menu, event.relatedTarget) &&
        !contains(menu, document.activeElement)) {
      menu.open = false;
    }
  });
  document.addEventListener("focusout", (event) => {
    const menu = menuFor(event.target);
    if (menu && !contains(menu, event.relatedTarget)) menu.open = false;
  });
  document.addEventListener("pointerdown", (event) => {
    document.querySelectorAll<HTMLDetailsElement>(`${selector}[open]`).forEach((menu) => {
      if (!contains(menu, event.target)) menu.open = false;
    });
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    document.querySelectorAll<HTMLDetailsElement>(`${selector}[open]`).forEach((menu) => {
      menu.open = false;
      if (contains(menu, document.activeElement)) menu.querySelector("summary")?.focus();
    });
  });
}
