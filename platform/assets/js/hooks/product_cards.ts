/**
 * The home page's product cards. Each card's line drawing is the ink of the
 * shared holographic foil (ash-template `hooks/holographic_card.ts`, drawn on
 * the island's canvas), lit where the pointer stands while it is over the card.
 * A card opens to show its details and its link: under a mouse while the
 * pointer is over it, from the keyboard when focus reaches it, and on a phone
 * with a tap on its title. The server renders every card closed and readable;
 * without this script a card opens on hover and focus from the stylesheet alone.
 */
import {createScope, stagger, type Scope} from "animejs"
import type {HolographicCardRenderer} from "../../vendor/regent_ui/holographic_card.mjs"
import {createCanvasIsland, type CanvasIslandController, type LoadRenderer} from "../canvas_island"
import {BASE, EASE_OUT, FAST, lastInputByPointer, play, still} from "./motion/shared"

/** A computed `rgb(…)` colour as the three 0..1 channels the renderer takes. */
const channels = (color: string): readonly [number, number, number] => {
  const [red = 0, green = 0, blue = 0] = (color.match(/[\d.]+/g) ?? []).map(Number)
  return [red / 255, green / 255, blue / 255]
}

/** The foil as the ink of the card's drawing, on the card's own fill. */
const browserLoadInk =
  (card: HTMLElement): LoadRenderer<HolographicCardRenderer> =>
  async (canvas, size, onDeviceLost) => {
    const {createHolographicCardRenderer, holographicInkMask} = await import(
      "../../vendor/regent_ui/holographic_card.mjs"
    )
    const drawing = canvas.closest(".rg-technical-figure__art")?.querySelector("svg")
    if (!drawing) throw new Error("foil ink needs the line drawing beside its canvas")
    canvas.style.maskImage = holographicInkMask(drawing)
    return createHolographicCardRenderer(canvas, size, onDeviceLost, {
      crown: false,
      ink: channels(getComputedStyle(drawing).color),
      ground: channels(getComputedStyle(card).backgroundColor),
    })
  }

const foilController = (card: HTMLElement): CanvasIslandController =>
  createCanvasIsland<HolographicCardRenderer>(card, {}, {
    canvasSelector: "[data-holo-canvas]",
    readyFlag: "holoReady",
    browserLoad: browserLoadInk(card),
    motionSensitive: true,
    continuous: false,
    interact({root, canvas, renderer, nudge}) {
      const fine = matchMedia("(pointer: fine)").matches
      const events = new AbortController()
      if (fine) {
        root.addEventListener("pointermove", (event: PointerEvent) => {
          if (!event.isPrimary) return
          const {left, top, width, height} = canvas().getBoundingClientRect()
          renderer()?.point([(event.clientX - left) / width, (event.clientY - top) / height])
          nudge()
        }, {passive: true, signal: events.signal})
        root.addEventListener("pointerleave", () => {
          renderer()?.rest()
          nudge()
        }, {passive: true, signal: events.signal})
      }
      return () => events.abort()
    },
  })

type FoilHook = {el: HTMLElement; controller?: CanvasIslandController; release?: () => void}

/**
 * One card's foil. The ink and its ground are the drawing's colours when the
 * renderer is made, so a theme switch makes it again in the new colours.
 */
export const ProductFoil = {
  mounted(this: FoilHook) {
    const start = () => {
      this.controller?.destroy()
      this.controller = foilController(this.el)
      this.controller.mount()
    }
    const theme = new MutationObserver(start)
    theme.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
    const scheme = matchMedia("(prefers-color-scheme: dark)")
    scheme.addEventListener("change", start)
    this.release = () => {
      theme.disconnect()
      scheme.removeEventListener("change", start)
    }
    start()
  },
  disconnected(this: FoilHook) {
    this.controller?.pause()
  },
  reconnected(this: FoilHook) {
    this.controller?.resume()
  },
  destroyed(this: FoilHook) {
    this.release?.()
    this.controller?.destroy()
    this.controller = undefined
  },
}

type CardsHook = {el: HTMLElement; scope?: Scope}

const hovers = () => matchMedia("(hover: hover) and (pointer: fine)").matches

/**
 * Opening and closing the cards. One card is open at a time. Its details grow
 * down from under the card and settle in; closing fades them out, quicker. Reduced motion,
 * and a card opened from the keyboard, simply show or hide.
 */
export const ProductCards = {
  mounted(this: CardsHook) {
    const root = this.el
    const scope = createScope({root})
    // Whether each card should end open, so a close that finishes after the
    // card was opened again leaves it open.
    const wanted = new WeakMap<HTMLElement, boolean>()
    const cards = () => [...root.querySelectorAll<HTMLElement>("[data-product]")]
    const head = (card: HTMLElement) => card.querySelector<HTMLButtonElement>("[aria-controls]")!
    const parts = (card: HTMLElement) => ({
      more: card.querySelector<HTMLElement>("[data-product-more]")!,
      fill: card.querySelector<HTMLElement>("[data-product-fill]")!,
      rows: [...card.querySelectorAll<HTMLElement>("[data-product-row]")],
    })

    this.scope = scope.add(() => {
      scope.add("open", (card: HTMLElement, moving: boolean) => {
        wanted.set(card, true)
        card.dataset.open = ""
        head(card).setAttribute("aria-expanded", "true")
        if (!moving) return
        const {more, fill, rows} = parts(card)
        // Stops a close still fading the details out.
        play(more, {opacity: 1, duration: FAST, ease: EASE_OUT})
        play(fill, {scaleY: {from: 0}, duration: BASE, ease: EASE_OUT})
        play(rows, {opacity: {from: 0}, y: {from: -6}, delay: stagger(30, {start: 60}), duration: BASE, ease: EASE_OUT})
      })

      scope.add("close", (card: HTMLElement, moving: boolean) => {
        wanted.set(card, false)
        head(card).setAttribute("aria-expanded", "false")
        if (!moving) return void delete card.dataset.open
        play(parts(card).more, {opacity: 0, duration: FAST, ease: EASE_OUT}).then(() => {
          if (!wanted.get(card)) delete card.dataset.open
        })
      })

      const isOpen = (card: HTMLElement) => wanted.get(card) === true
      const open = (card: HTMLElement, moving: boolean) => {
        for (const other of cards()) if (other !== card && isOpen(other)) scope.methods.close(other, moving)
        if (!isOpen(card)) scope.methods.open(card, moving && !still(root))
      }
      const close = (card: HTMLElement, moving: boolean) => {
        if (isOpen(card)) scope.methods.close(card, moving && !still(root))
      }
      const cardOf = (target: EventTarget | null) =>
        target instanceof Element ? target.closest<HTMLElement>("[data-product]") : null

      const events = new AbortController()
      const options = {signal: events.signal}

      // A mouse opens the card it is over and closes it on leaving.
      root.addEventListener("pointerover", event => {
        const card = cardOf(event.target)
        if (card && event.pointerType === "mouse" && hovers()) open(card, true)
      }, options)
      root.addEventListener("pointerout", event => {
        const card = cardOf(event.target)
        if (!card || event.pointerType !== "mouse" || !hovers()) return
        if (cardOf(event.relatedTarget) !== card && !card.contains(document.activeElement)) close(card, true)
      }, options)

      // A press on a card's title: a mouse has already opened it; a finger opens
      // or closes it; a key press opens it at once.
      root.addEventListener("click", event => {
        const button = event.target instanceof Element ? event.target.closest("[aria-controls]") : null
        const card = cardOf(button)
        if (!card) return
        const byHand = event.detail > 0
        if (byHand && !hovers() && isOpen(card)) close(card, true)
        else open(card, byHand)
      }, options)

      // Focus that arrives from the keyboard opens its card at once; focus that
      // leaves for somewhere else closes it, unless the mouse is still over it.
      // Escape hands focus back to the title of the card it closed, which keeps
      // it closed.
      let returning: HTMLElement | null = null
      root.addEventListener("focusin", event => {
        const card = cardOf(event.target)
        if (card && card !== returning && !lastInputByPointer()) open(card, false)
      }, options)
      root.addEventListener("focusout", event => {
        const card = cardOf(event.target)
        if (card && cardOf(event.relatedTarget) !== card && !card.matches(":hover")) close(card, false)
      }, options)

      // Escape closes the open card wherever focus is; from inside the card,
      // focus goes back to its title.
      document.addEventListener("keydown", event => {
        if (event.key !== "Escape") return
        for (const card of cards()) {
          if (!isOpen(card)) continue
          close(card, false)
          if (!card.contains(document.activeElement)) continue
          returning = card
          head(card).focus()
          returning = null
        }
      }, options)

      // A tap anywhere outside the open card closes it.
      document.addEventListener("pointerdown", event => {
        if (hovers()) return
        for (const card of cards()) if (isOpen(card) && cardOf(event.target) !== card) close(card, true)
      }, options)

      root.dataset.ready = ""
      return () => {
        events.abort()
        delete root.dataset.ready
      }
    })
  },

  destroyed(this: CardsHook) {
    this.scope?.revert()
  },
}
