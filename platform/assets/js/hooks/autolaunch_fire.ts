import type {Hook} from "../hook_composition"

type FireHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): void
  fireLayer?: HTMLElement
  fireTimers?: Set<number>
  fireLastSent?: number
  fireAuction?: string
  removeFireClick?: () => void
}

export const HOLD_MS = 2000
export const FADE_MS = 500
export const COOLDOWN_MS = 2000
export const MAX_FLAMES = 40

// A click on anything a person operates, or while text is selected, is that
// action and not a flame.
const CONTROLS = "a, button, input, select, textarea, label, summary, [contenteditable], [role=button]"

/** Whether a click lights a flame rather than operating something on the page. */
export function lights(target: EventTarget | null, selection: Selection | null): boolean {
  if (!(target instanceof Element)) return false
  if (target.closest(CONTROLS)) return false
  return !(selection && selection.type === "Range")
}

/** The click's place as fractions of the page, or null when it is outside. */
export function pagePoint(
  x: number,
  y: number,
  width: number,
  height: number,
): {x: number; y: number} | null {
  if (!(width > 0 && height > 0)) return null
  const point = {x: x / width, y: y / height}
  return insidePage(point) ? point : null
}

/** A payload counts only as two finite fractions inside the page. */
export function insidePage(payload: unknown): payload is {x: number; y: number} {
  if (typeof payload !== "object" || payload === null) return false
  const {x, y} = payload as {x?: unknown; y?: unknown}
  return [x, y].every(v => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1)
}

/** A flame belongs on this page only when it names the auction the page shows. */
export function forAuction(payload: unknown, auction: string | undefined): boolean {
  return (
    typeof payload === "object" &&
    payload !== null &&
    auction !== undefined &&
    (payload as {auction?: unknown}).auction === auction
  )
}

/** Drops every flame and pending timer, for a page that now shows another auction. */
export function clearFlames(layer: HTMLElement, timers: Set<number>): void {
  timers.forEach(timer => window.clearTimeout(timer))
  timers.clear()
  layer.replaceChildren()
}

/** Shows one flame that holds, fades, and is removed; never more than the cap at once. */
export function spawnFlame(
  layer: HTMLElement,
  point: {x: number; y: number},
  timers: Set<number>,
  still: boolean,
): void {
  while (layer.childElementCount >= MAX_FLAMES) layer.firstElementChild?.remove()
  const flame = document.createElement("span")
  flame.className = still ? "auction-fire__flame auction-fire__flame--still" : "auction-fire__flame"
  flame.textContent = "🔥"
  flame.setAttribute("aria-hidden", "true")
  flame.style.left = `${point.x * 100}%`
  flame.style.top = `${point.y * 100}%`
  layer.append(flame)
  const fade = window.setTimeout(() => {
    timers.delete(fade)
    flame.classList.add("auction-fire__flame--fading")
  }, HOLD_MS)
  const gone = window.setTimeout(() => {
    timers.delete(gone)
    flame.remove()
  }, HOLD_MS + FADE_MS)
  timers.add(fade)
  timers.add(gone)
}

export const AutolaunchFire: Hook = {
  mounted(this: FireHook) {
    const layer = document.createElement("div")
    layer.className = "auction-fire"
    layer.setAttribute("aria-hidden", "true")
    document.body.append(layer)
    this.fireLayer = layer
    this.fireTimers = new Set()
    this.fireLastSent = -Infinity
    this.fireAuction = this.el.dataset.auctionId

    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.handleEvent("auction-fire", payload => {
      if (forAuction(payload, this.fireAuction) && insidePage(payload)) {
        spawnFlame(layer, payload, this.fireTimers!, still)
      }
    })

    const onClick = (event: MouseEvent) => {
      if (!lights(event.target, document.getSelection())) return
      const now = performance.now()
      if (now - this.fireLastSent! < COOLDOWN_MS) return
      const point = pagePoint(event.clientX, event.clientY, window.innerWidth, window.innerHeight)
      if (!point) return
      this.fireLastSent = now
      this.pushEventTo(this.el, "fire", point)
    }
    document.addEventListener("click", onClick)
    this.removeFireClick = () => document.removeEventListener("click", onClick)
  },
  updated(this: FireHook) {
    const auction = this.el.dataset.auctionId
    if (auction === this.fireAuction) return
    this.fireAuction = auction
    clearFlames(this.fireLayer!, this.fireTimers!)
  },
  destroyed(this: FireHook) {
    this.removeFireClick?.()
    this.fireTimers?.forEach(timer => window.clearTimeout(timer))
    this.fireTimers?.clear()
    this.fireLayer?.remove()
  },
}
