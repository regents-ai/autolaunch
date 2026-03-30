import type { Hook } from "phoenix_live_view"

import {
  prefersReducedMotion,
  pulseElement,
  revealSequence,
} from "../../../../packages/regent_ui/assets/js/regent_motion"

interface MotionRoot extends HTMLElement {
  _missionMotionClick?: (event: Event) => void
  _missionMotionInput?: (event: Event) => void
}

interface CopyButton extends HTMLElement {
  _missionMotionUpdateTimer?: number
}

const UPDATE_TARGET_SELECTOR =
  ".al-stat-card, .al-auction-tile, .al-position-card, .al-review-card, .al-note-card, .al-inline-banner, .al-step-chip, .al-ingress-card, .al-contract-card, .al-contract-list-item"

function reducedMotion(): boolean {
  return prefersReducedMotion()
}

function pulse(element: HTMLElement, duration = 560): void {
  element.classList.add("is-updated")
  pulseElement(element, duration)
  window.setTimeout(() => {
    element.classList.remove("is-updated")
  }, duration + 160)
}

function motionSignature(target: HTMLElement): string {
  if (target instanceof HTMLInputElement) {
    return [
      target.value,
      target.checked ? "checked" : "unchecked",
      target.disabled ? "disabled" : "enabled",
    ].join("|")
  }

  if (target instanceof HTMLSelectElement || target instanceof HTMLTextAreaElement) {
    return [target.value, target.disabled ? "disabled" : "enabled"].join("|")
  }

  return target.textContent?.replace(/\s+/g, " ").trim() || ""
}

function animateIntro(root: MotionRoot): void {
  const selectors =
    root.id === "launch-onboard"
      ? ".al-onboard-summary > *, .al-onboard-card"
      : root.id === "launch-wizard"
        ? ".al-step-chip, .al-main-panel, .al-side-panel"
        : root.id === "launch-hero" || root.id === "auction-detail-hero" || root.id === "auctions-hero" || root.id === "positions-hero" || root.id === "subject-hero" || root.id === "contracts-hero"
          ? ":scope > *"
          : ""

  if (selectors === "") {
    return
  }

  revealSequence(root, selectors, {
    translateY: root.id === "launch-wizard" ? 16 : 24,
    delay: root.id === "launch-wizard" ? 50 : 80,
    duration: root.id === "launch-wizard" ? 560 : 660,
  })

  if (root.id === "launch-hero" || root.id === "auction-detail-hero" || root.id === "auctions-hero" || root.id === "positions-hero" || root.id === "subject-hero" || root.id === "contracts-hero") {
    revealSequence(root, ".al-stat-card", { translateY: 18, delay: 70, duration: 560 })
  }
}

function syncChangeFeedback(root: MotionRoot): void {
  const targets = Array.from(root.querySelectorAll<HTMLElement>(UPDATE_TARGET_SELECTOR))

  for (const target of targets) {
    const previous = target.dataset.motionSignature
    const next = motionSignature(target)

    if (previous && previous !== next) {
      pulse(target)
    }

    target.dataset.motionSignature = next
  }
}

function addFieldFeedback(root: MotionRoot): void {
  root._missionMotionInput = (event: Event) => {
    const target = event.target as HTMLElement | null
    if (!target) return

    const field = target.closest<HTMLElement>("input, select, textarea")
    if (!field || !root.contains(field)) return

    field.classList.add("is-updated")
    pulse(field, 420)
  }

  root.addEventListener("input", root._missionMotionInput)
  root.addEventListener("change", root._missionMotionInput)
}

function addCopyFeedback(root: MotionRoot): void {
  root._missionMotionClick = (event: Event) => {
    const target = event.target as HTMLElement | null
    if (!target) return

    const copyButton = target.closest<HTMLElement>("[data-copy-value]")
    if (copyButton) {
      const button = copyButton as CopyButton
      const value = copyButton.dataset.copyValue || ""
      if (value) {
        void navigator.clipboard.writeText(value)
      }

      const originalLabel = button.dataset.copyLabel || button.textContent?.trim() || "Copy"

      button.dataset.copyLabel = originalLabel
      button.dataset.copyState = "copied"
      button.textContent = "Copied"
      pulse(button, 260)

      if (button._missionMotionUpdateTimer) {
        window.clearTimeout(button._missionMotionUpdateTimer)
      }

      button._missionMotionUpdateTimer = window.setTimeout(() => {
        button.dataset.copyState = "idle"
        button.textContent = originalLabel
        button.classList.remove("is-updated")
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
}

export const MissionMotion: Hook = {
  mounted() {
    const root = this.el as MotionRoot
    addCopyFeedback(root)
    addFieldFeedback(root)
    animateIntro(root)
    syncChangeFeedback(root)
  },

  updated() {
    const root = this.el as MotionRoot
    syncChangeFeedback(root)
  },

  destroyed() {
    const root = this.el as MotionRoot

    if (root._missionMotionClick) {
      root.removeEventListener("click", root._missionMotionClick)
    }

    if (root._missionMotionInput) {
      root.removeEventListener("input", root._missionMotionInput)
      root.removeEventListener("change", root._missionMotionInput)
    }
  },
}
