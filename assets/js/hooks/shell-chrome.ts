import type { Hook } from "phoenix_live_view"

import { animate } from "../../vendor/anime.esm.js"

import {
  prefersReducedMotion,
  pulseElement,
} from "../regent_motion.ts"

interface ShellRoot extends HTMLElement {
  _shellChromeClick?: (event: Event) => void
  _shellChromeKeydown?: (event: KeyboardEvent) => void
  _shellChromeInput?: (event: Event) => void
  _shellChromeSubmit?: (event: Event) => void
}

interface CopyButton extends HTMLElement {
  _shellChromeResetTimer?: number
}

function reducedMotion(): boolean {
  return prefersReducedMotion()
}

function animateButton(button: HTMLElement): void {
  if (reducedMotion()) {
    pulseElement(button, 220)
    return
  }

  animate(button, {
    scale: [{ to: 0.985, duration: 80 }, { to: 1, duration: 220 }],
    translateY: [{ to: 1.5, duration: 80 }, { to: 0, duration: 220 }],
    duration: 300,
    ease: "outExpo",
  })
}

function copyValue(button: CopyButton): void {
  const value = button.dataset.copyValue || ""
  if (!value) return

  void navigator.clipboard.writeText(value)

  const originalLabel = button.dataset.copyLabel || button.textContent?.trim() || "Copy"
  button.dataset.copyLabel = originalLabel
  button.dataset.copyState = "copied"
  button.textContent = "Copied"

  animateButton(button)

  if (button._shellChromeResetTimer) {
    window.clearTimeout(button._shellChromeResetTimer)
  }

  button._shellChromeResetTimer = window.setTimeout(() => {
    button.dataset.copyState = "idle"
    button.textContent = originalLabel
  }, 1400)
}

function toggleTheme(button: HTMLElement): void {
  const current = document.documentElement.getAttribute("data-theme") || "light"
  const next = current === "light" ? "dark" : "light"

  animateButton(button)
  window.dispatchEvent(new CustomEvent("autolaunch:set-theme", { detail: { theme: next } }))
}

function commandPalette(root: HTMLElement): HTMLElement | null {
  return root.querySelector<HTMLElement>("[data-command-palette]")
}

function commandInput(root: HTMLElement): HTMLInputElement | null {
  return root.querySelector<HTMLInputElement>("[data-command-input]")
}

function commandItems(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>("[data-command-item]"))
}

function queryActions(root: HTMLElement): HTMLAnchorElement[] {
  return Array.from(root.querySelectorAll<HTMLAnchorElement>("[data-command-query-action]"))
}

function openCommandPalette(root: HTMLElement): void {
  const palette = commandPalette(root)
  const input = commandInput(root)
  if (!palette || !input) return

  palette.hidden = false
  input.value = ""
  updateCommandResults(root)
  window.setTimeout(() => input.focus(), 0)

  if (!reducedMotion()) {
    const dialog = palette.querySelector<HTMLElement>(".al-command-dialog")
    if (dialog) {
      animate(dialog, {
        opacity: [{ to: 1, duration: 160 }],
        translateY: [{ from: -8, to: 0, duration: 260 }],
        scale: [{ from: 0.985, to: 1, duration: 260 }],
        ease: "outExpo",
      })
    }
  }
}

function closeCommandPalette(root: HTMLElement): void {
  const palette = commandPalette(root)
  if (!palette) return
  palette.hidden = true
}

function updateCommandResults(root: HTMLElement): void {
  const input = commandInput(root)
  const query = input?.value.trim().toLowerCase() || ""
  let visibleCount = 0

  commandItems(root).forEach((item) => {
    const haystack = item.dataset.commandSearch || item.textContent?.toLowerCase() || ""
    const visible = query === "" || haystack.includes(query)
    item.hidden = !visible
    if (visible) visibleCount += 1
  })

  queryActions(root).forEach((action) => {
    const visible = query.length > 1
    action.hidden = !visible

    if (visible) {
      const template = action.dataset.commandQueryTemplate || action.href
      const encoded = encodeURIComponent(query)
      action.href = template.replace("__QUERY__", encoded)

      const label = action.querySelector<HTMLElement>("[data-command-query-label]")
      if (label) {
        label.textContent = `${label.dataset.commandQueryLabel} for "${query}"`
      }
    }
  })

  const empty = root.querySelector<HTMLElement>("[data-command-empty]")
  if (empty) {
    empty.hidden = visibleCount > 0 || query.length > 1
  }
}

function handleGlobalShortcut(event: KeyboardEvent, root: HTMLElement): void {
  const key = event.key.toLowerCase()
  if (key !== "k" || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) {
    return
  }

  const target = event.target as HTMLElement | null
  if (target && (target.matches("input, textarea, select") || target.isContentEditable)) {
    return
  }

  event.preventDefault()
  openCommandPalette(root)
}

export const ShellChrome: Hook = {
  mounted() {
    const root = this.el as ShellRoot
    root.dataset.shellChromeRoot = "true"

    root._shellChromeClick = (event: Event) => {
      const target = event.target as HTMLElement | null
      if (!target) return

      const owner = target.closest<HTMLElement>("[data-shell-chrome-root='true']")
      if (owner && owner !== root) return

      const openTarget = target.closest<HTMLElement>("[data-command-open]")
      if (openTarget && root.contains(openTarget)) {
        event.preventDefault()
        openCommandPalette(root)
        return
      }

      const closeTarget = target.closest<HTMLElement>("[data-command-close]")
      if (closeTarget && root.contains(closeTarget)) {
        event.preventDefault()
        closeCommandPalette(root)
        return
      }

      const copyButton = target.closest<CopyButton>("[data-copy-value]")
      if (copyButton && root.contains(copyButton)) {
        copyValue(copyButton)
        return
      }

      const themeButton = target.closest<HTMLElement>("[data-theme-action='toggle']")
      if (themeButton && root.contains(themeButton)) {
        toggleTheme(themeButton)
      }
    }

    root.addEventListener("click", root._shellChromeClick)

    root._shellChromeInput = (event: Event) => {
      const target = event.target as HTMLElement | null
      if (target?.matches("[data-command-input]")) {
        updateCommandResults(root)
      }
    }

    root.addEventListener("input", root._shellChromeInput)

    root._shellChromeSubmit = (event: Event) => {
      const target = event.target as HTMLElement | null
      if (target?.matches("[data-command-open]")) {
        event.preventDefault()
        openCommandPalette(root)
      }
    }

    root.addEventListener("submit", root._shellChromeSubmit)

    root._shellChromeKeydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeCommandPalette(root)
        return
      }

      handleGlobalShortcut(event, root)
    }

    if (typeof window.addEventListener === "function") {
      window.addEventListener("keydown", root._shellChromeKeydown)
    }
  },

  destroyed() {
    const root = this.el as ShellRoot

    if (root._shellChromeClick) {
      root.removeEventListener("click", root._shellChromeClick)
    }

    if (root._shellChromeInput) {
      root.removeEventListener("input", root._shellChromeInput)
    }

    if (root._shellChromeSubmit) {
      root.removeEventListener("submit", root._shellChromeSubmit)
    }

    if (root._shellChromeKeydown && typeof window.removeEventListener === "function") {
      window.removeEventListener("keydown", root._shellChromeKeydown)
    }

    delete root.dataset.shellChromeRoot
  },
}
