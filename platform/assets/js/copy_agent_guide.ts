// "Copy to Agent" puts the whole agent guide on the clipboard. The clipboard
// item is given the download itself, so the copy still counts as part of the
// press in browsers that only allow copying during one.
export function installCopyAgentGuide(): void {
  const timers = new WeakMap<HTMLElement, number>()

  document.addEventListener("click", async (event) => {
    const button =
      event.target instanceof Element
        ? event.target.closest<HTMLElement>("[data-copy-agent-guide]")
        : null
    const label = button?.querySelector<HTMLElement>("[data-copy-agent-label]")
    if (!button || !label) return

    const guide = fetch(button.dataset.copyAgentGuide!, {cache: "no-store"})
      .then((response) => {
        if (!response.ok) throw new Error(`Agent guide returned ${response.status}`)
        return response.text()
      })
      .then((text) => new Blob([text], {type: "text/plain"}))

    try {
      await navigator.clipboard.write([new ClipboardItem({"text/plain": guide})])
      label.textContent = "Copied"
    } catch {
      label.textContent = "Couldn't copy"
    }
    window.clearTimeout(timers.get(button))
    timers.set(button, window.setTimeout(() => (label.textContent = "Copy to Agent"), 3000))
  })
}
