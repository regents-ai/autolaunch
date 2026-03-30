import type { Hook } from "phoenix_live_view"

import {
  prefersReducedMotion,
  pulseElement,
  revealSequence,
} from "../../../../packages/regent_ui/assets/js/regent_motion"

interface GuideRoot extends HTMLElement {
  _guideObserver?: IntersectionObserver
  _guideScroll?: () => void
  _guideFrame?: number
}

function reducedMotion(): boolean {
  return prefersReducedMotion()
}

function updateProgress(root: GuideRoot): void {
  const fill = root.querySelector<HTMLElement>("[data-guide-progress-fill]")
  const rail = root.querySelector<HTMLElement>(".al-guide-layout")
  if (!fill || !rail) return

  const rect = rail.getBoundingClientRect()
  const viewport = window.innerHeight || document.documentElement.clientHeight
  const start = viewport * 0.18
  const end = viewport * 0.82
  const maxTravel = Math.max(rect.height - (end - start), 1)
  const progress = Math.min(Math.max((start - rect.top) / maxTravel, 0), 1)

  fill.style.setProperty("--guide-progress", progress.toString())
}

function reveal(root: GuideRoot): void {
  revealSequence(root, ".al-guide-hero-copy > *, .al-guide-summary, .al-guide-rail, .al-guide-finish", {
    translateY: 24,
    delay: 90,
    duration: 700,
  })
}

function observeSteps(root: GuideRoot): void {
  const steps = Array.from(root.querySelectorAll<HTMLElement>("[data-guide-step]"))
  if (steps.length === 0) return

  if (reducedMotion()) {
    steps.forEach((step) => step.classList.add("is-visible"))
    const fill = root.querySelector<HTMLElement>("[data-guide-progress-fill]")
    if (fill) fill.style.setProperty("--guide-progress", "1")
    return
  }

  const seen = new Set<number>()

  root._guideObserver = new IntersectionObserver(
    (entries) => {
      let nearest: number | null = null

      for (const entry of entries) {
        if (!entry.isIntersecting) continue

        const step = entry.target as HTMLElement
        const index = Number(step.dataset.guideIndex || "0")
        nearest = nearest === null ? index : Math.min(nearest, index)

        if (!seen.has(index)) {
          seen.add(index)
          step.classList.add("is-visible")
          pulseElement(step, 420)
          revealSequence(
            step,
            ".al-guide-step-index, .al-guide-step-copy, .al-guide-step-callout",
            { translateY: 12, delay: 60, duration: 560 },
          )
        }
      }

      if (nearest !== null) {
        const progress = Math.min(Math.max(nearest / Math.max(steps.length - 1, 1), 0), 1)
        const fill = root.querySelector<HTMLElement>("[data-guide-progress-fill]")
        if (fill) fill.style.setProperty("--guide-progress", progress.toString())
      }
    },
    {
      threshold: 0.36,
      rootMargin: "-10% 0px -16% 0px",
    },
  )

  for (const step of steps) {
    step.style.opacity = "0"
    step.style.transform = "translateY(22px)"
    root._guideObserver.observe(step)
  }
}

function mountScroll(root: GuideRoot): void {
  if (reducedMotion()) {
    updateProgress(root)
    return
  }

  const onScroll = () => {
    if (root._guideFrame) {
      cancelAnimationFrame(root._guideFrame)
    }

    root._guideFrame = window.requestAnimationFrame(() => updateProgress(root))
  }

  root._guideScroll = onScroll
  window.addEventListener("scroll", onScroll, { passive: true })
  updateProgress(root)
}

function teardown(root: GuideRoot): void {
  root._guideObserver?.disconnect()
  root._guideObserver = undefined

  if (root._guideScroll) {
    window.removeEventListener("scroll", root._guideScroll)
    root._guideScroll = undefined
  }

  if (root._guideFrame) {
    cancelAnimationFrame(root._guideFrame)
    root._guideFrame = undefined
  }
}

export const AuctionGuideMotion: Hook = {
  mounted() {
    const root = this.el as GuideRoot
    teardown(root)
    reveal(root)
    observeSteps(root)
    mountScroll(root)
  },

  updated() {
    const root = this.el as GuideRoot
    teardown(root)
    observeSteps(root)
    mountScroll(root)
  },

  destroyed() {
    teardown(this.el as GuideRoot)
  },
}
