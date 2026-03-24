import type { Hook } from "phoenix_live_view"

import { animate, stagger } from "../../vendor/anime.esm.js"

interface MotionRoot extends HTMLElement {
  _missionMotionClick?: (event: Event) => void
}

interface CopyButton extends HTMLElement {
  _copyResetTimer?: number
}

export const MissionMotion: Hook = {
  mounted() {
    const root = this.el as MotionRoot
    const heroTargets = root.matches(".al-hero, .al-detail-hero") ? root : root.querySelectorAll(".al-hero, .al-detail-hero")
    const cardTargets = root.querySelectorAll(".al-panel, .al-agent-card, .al-auction-tile, .al-position-card")

    animate(heroTargets, {
      opacity: [0, 1],
      translateY: [24, 0],
      duration: 640,
      ease: "outExpo",
    })

    animate(cardTargets, {
      opacity: [0, 1],
      translateY: [28, 0],
      delay: stagger(90),
      duration: 700,
      ease: "outExpo",
    })

    root._missionMotionClick = (event: Event) => {
      const target = event.target as HTMLElement | null
      if (!target) return

      const copyButton = target.closest<HTMLElement>("[data-copy-value]")
      if (copyButton) {
        const value = copyButton.dataset.copyValue || ""
        if (value) {
          void navigator.clipboard.writeText(value)
        }

        const button = copyButton as CopyButton
        const originalLabel = button.dataset.copyLabel || button.textContent?.trim() || "Copy"

        button.dataset.copyLabel = originalLabel
        button.dataset.copyState = "copied"
        button.textContent = "Copied"

        animate(button, {
          scale: [0.98, 1],
          duration: 220,
          ease: "outExpo",
        })

        if (button._copyResetTimer) {
          window.clearTimeout(button._copyResetTimer)
        }

        button._copyResetTimer = window.setTimeout(() => {
          button.dataset.copyState = "idle"
          button.textContent = originalLabel
        }, 1400)

        return
      }

      const themeButton = target.closest<HTMLElement>("[data-theme-action='toggle']")
      if (!themeButton) return

      const current = document.documentElement.getAttribute("data-theme") || "dawn"
      const next = current === "dawn" ? "midnight" : "dawn"
      window.dispatchEvent(new CustomEvent("autolaunch:set-theme", { detail: { theme: next } }))
    }

    root.addEventListener("click", root._missionMotionClick)
  },

  destroyed() {
    const root = this.el as MotionRoot
    if (root._missionMotionClick) {
      root.removeEventListener("click", root._missionMotionClick)
    }
  },
}
