import type { Hook } from "phoenix_live_view"

import { animate } from "../../vendor/anime.esm.js"

import {
  prefersReducedMotion,
  pulseElement,
} from "../../../../packages/regent_ui/assets/js/regent_motion.ts"

interface ShellRoot extends HTMLElement {
  _shellChromeClick?: (event: Event) => void
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
  const current = document.documentElement.getAttribute("data-theme") || "dawn"
  const next = current === "dawn" ? "midnight" : "dawn"

  animateButton(button)
  window.dispatchEvent(new CustomEvent("autolaunch:set-theme", { detail: { theme: next } }))
}

export const ShellChrome: Hook = {
  mounted() {
    const root = this.el as ShellRoot

    root._shellChromeClick = (event: Event) => {
      const target = event.target as HTMLElement | null
      if (!target) return

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
  },

  destroyed() {
    const root = this.el as ShellRoot

    if (root._shellChromeClick) {
      root.removeEventListener("click", root._shellChromeClick)
    }
  },
}
