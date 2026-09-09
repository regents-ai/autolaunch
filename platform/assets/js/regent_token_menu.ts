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

  // The $REGENT heading copies the contract address: green check and a fading
  // "CA copied" toast for three seconds, then back to the copy glyph.
  const timers = new WeakMap<HTMLElement, number>();
  const restore = (button: HTMLElement) => {
    button.classList.remove("is-copied");
    const copyGlyph = button.querySelector<HTMLElement>("[data-copy-glyph]");
    const checkGlyph = button.querySelector<HTMLElement>("[data-check-glyph]");
    const toast = button.querySelector<HTMLElement>("[data-copy-toast]");
    if (copyGlyph) copyGlyph.hidden = false;
    if (checkGlyph) checkGlyph.hidden = true;
    if (toast) toast.textContent = "";
  };
  document.addEventListener("click", async (event) => {
    const button =
      event.target instanceof Element
        ? event.target.closest<HTMLElement>("[data-regent-copy]")
        : null;
    if (!button) return;
    const address = button.dataset.copyAddress;
    if (!address) return;
    try {
      await navigator.clipboard.writeText(address);
    } catch {
      return;
    }
    const copyGlyph = button.querySelector<HTMLElement>("[data-copy-glyph]");
    const checkGlyph = button.querySelector<HTMLElement>("[data-check-glyph]");
    const toast = button.querySelector<HTMLElement>("[data-copy-toast]");
    if (copyGlyph) copyGlyph.hidden = true;
    if (checkGlyph) checkGlyph.hidden = false;
    if (toast) toast.textContent = "CA copied";
    button.classList.add("is-copied");
    window.clearTimeout(timers.get(button));
    timers.set(button, window.setTimeout(() => restore(button), 3000));
  });
}
