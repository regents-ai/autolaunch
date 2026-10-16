/**
 * The list of tools agents see (`AgentTools`), on every page that shows its
 * button, from one listener on the document. The button opens the dialog its
 * `aria-controls` names; the dialog's X, Escape, or a press on its backdrop,
 * which lands on the dialog itself, closes it.
 */
export function installAgentTools() {
  document.addEventListener("click", event => {
    const target = event.target instanceof Element ? event.target : null
    const opener = target?.closest<HTMLButtonElement>("[data-agent-tools-open]")
    const dialog = opener && document.getElementById(opener.getAttribute("aria-controls") ?? "")
    if (dialog instanceof HTMLDialogElement) return dialog.showModal()

    const shown = target?.closest<HTMLDialogElement>("dialog[data-agent-tools]")
    if (shown && (target === shown || target?.closest("[data-agent-tools-close]"))) shown.close()
  })
}
