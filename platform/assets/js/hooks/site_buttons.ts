/**
 * The site's main buttons, as the template's motion-lab study of them has them
 * (ash-template design-motion b3b913e, `site_buttons_lab.ts`, Autolaunch's
 * "With motion" column): a whole-button press dip that springs back, and a
 * soft VGPU light in the site colour behind them that follows the pointer and
 * then stops drawing. A button takes part by carrying `data-press="motion"`,
 * which also keeps the kit's label squish off it. Nothing moves under reduced
 * motion, and a key press only sets `data-input`, so the stylesheet shows its
 * answer at once. No press waits for, or is stopped by, the motion.
 */
import {animate, createScope, utils, type JSAnimation, type Scope} from "animejs"
import {createCanvasIsland, type CanvasIslandController} from "../canvas_island"
import {EASE_IN_OUT, EASE_OUT, FAST, SLOW, play, still} from "./motion/shared"
import type {LightAim, LightRenderer, Rgb} from "../site_buttons_light"

type ButtonsHook = {el: HTMLElement; scope?: Scope; release?: () => void}

/** The whole button gives a little under a pointer press and comes back on release; its words
 *  never move on their own. */
export const SiteButtons = {
  mounted(this: ButtonsHook) {
    const root = this.el
    let press: JSAnimation | undefined
    let pressed: HTMLElement | null = null
    const scope = createScope({root})
    this.scope = scope.add(() => {
      scope.add("press", (button: HTMLElement, scale: number) => { press = animate(button, {scale: [scale, .98], duration: FAST, ease: EASE_OUT}) })
      scope.add("release", (button: HTMLElement) => {
        const scale = Number(utils.get(button, "scale")) || 1
        press?.revert()
        press = undefined
        play(button, {scale: [scale, 1], duration: FAST * .75, ease: EASE_OUT})
      })
    })
    const events = new AbortController()
    const options = {signal: events.signal}
    const clearPress = () => {
      if (pressed && !still(root)) scope.methods.release(pressed)
      pressed = null
    }
    root.addEventListener("pointerdown", event => {
      root.dataset.input = "pointer"
      if (event.button !== 0 || !event.isPrimary || still(root)) return
      const button = event.target instanceof Element ? event.target.closest<HTMLElement>("[data-press='motion']") : null
      if (!button || button.matches(":disabled, [aria-disabled='true']")) return
      const scale = Number(utils.get(button, "scale")) || 1
      scope.refresh() // Completed runs retire, so repeated presses never pile up.
      pressed = button
      scope.methods.press(button, scale)
    }, options)
    root.addEventListener("keydown", () => {
      root.dataset.input = "key"
      pressed = null
      scope.refresh()
    }, options)
    document.addEventListener("pointerup", clearPress, options)
    document.addEventListener("pointercancel", clearPress, options)
    window.addEventListener("blur", clearPress, options)
    this.release = () => events.abort()
  },
  disconnected(this: ButtonsHook) { this.scope?.refresh() },
  destroyed(this: ButtonsHook) { this.release?.(); this.scope?.revert() },
}

// How bright the light rests, and how much a pointer over its ground adds.
const GLOW = .4
const HOVER_GLOW = .25

let probe: CanvasRenderingContext2D | null | undefined

/** Any colour the stylesheet computes, as the three channels the shader takes. */
const rgb = (color: string): Rgb => {
  probe ??= Object.assign(document.createElement("canvas"), {width: 1, height: 1}).getContext("2d", {willReadFrequently: true})
  if (!probe) return [0, 0, 0]
  probe.clearRect(0, 0, 1, 1)
  probe.fillStyle = "#000"
  probe.fillStyle = color
  probe.fillRect(0, 0, 1, 1)
  const [r, g, b] = probe.getImageData(0, 0, 1, 1).data
  return [r / 255, g / 255, b / 255]
}

type Point = {x: number; y: number}

type LightHook = {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: {from?: unknown}) => void): void
  controller?: CanvasIslandController
  sync?: () => void
  follow?: (at: Point) => void
  release?: () => void
}

// How long the light takes to swirl into Stake, and how many glows trail it.
const SWIRL = 1300
const TRAIL = 6

/** Where the swirl is `t` of the way from `from` into `to`: once around `to`, closing in. */
const swirlAt = ({from, to}: {from: Point; to: Point}, t: number): Point => {
  const reach = Math.hypot(from.x - to.x, from.y - to.y)
  const start = Math.atan2(from.y - to.y, from.x - to.x)
  const angle = start + t * Math.PI * 2
  const radius = reach * (1 - t) ** 1.6
  return {x: to.x + Math.cos(angle) * radius, y: to.y + Math.sin(angle) * radius * .55}
}

const middle = (el: Element, box: DOMRect): Point => {
  const at = el.getBoundingClientRect()
  return {x: at.left + at.width / 2 - box.left, y: at.top + at.height / 2 - box.top}
}

/** The VGPU light behind a group of the site's buttons: it follows the pointer over its ground
 *  and otherwise rests on the first button showing, then stops drawing. The still face
 *  underneath is what shows until a frame lands. After a confirmed claim the server sends
 *  `stake-light`: a green light swirls from the claim button into the Stake button (the
 *  Stake tab while that is not showing), the line under it fades in as it arrives, and the
 *  light goes back to rest. Nothing moves under
 *  reduced motion, and nothing waits on it. */
export const SiteLight = {
  mounted(this: LightHook) {
    const root = this.el
    const stage = root.parentElement!
    const button = () =>
      [...stage.querySelectorAll<HTMLElement>("[data-press='motion']")].find(el => el.offsetParent !== null && !el.closest("[inert]"))
    let pointer: {x: number; y: number} | null = null

    const aim = (): LightAim => {
      const box = root.getBoundingClientRect()
      if (pointer) return {x: pointer.x, y: pointer.y, glow: GLOW + HOVER_GLOW}
      const at = button()?.getBoundingClientRect()
      if (!at || box.width === 0 || box.height === 0) return {x: .5, y: .5, glow: GLOW}
      return {x: (at.left + at.width / 2 - box.left) / box.width, y: (at.top + at.height / 2 - box.top) / box.height, glow: GLOW}
    }

    this.controller = createCanvasIsland<LightRenderer>(root, {}, {
      canvasSelector: "[data-light-canvas]",
      readyFlag: "lightReady",
      motionSensitive: true,
      // The light moves only when the pointer or the buttons do.
      continuous: false,
      browserLoad: async (canvas, size, lost) => {
        const {createLightRenderer} = await import("../site_buttons_light")
        return createLightRenderer(canvas, size, lost)
      },
      interact: ({renderer, nudge, onReady}) => {
        // Colours are read when they can change (a new renderer, the theme), never per
        // pointer move; the shader is only written what changed.
        const paint = () => {
          const style = getComputedStyle(root)
          renderer()?.colors(rgb(style.backgroundColor), rgb(style.color))
        }
        const sync = (jump = false) => {
          renderer()?.aim(aim(), jump)
          nudge()
        }
        const keyed = () => stage.closest<HTMLElement>("[data-input]")?.dataset.input === "key"
        const events = new AbortController()
        const options = {signal: events.signal}
        stage.addEventListener("pointermove", event => {
          if (event.pointerType !== "mouse") return
          const box = root.getBoundingClientRect()
          pointer = {x: (event.clientX - box.left) / box.width, y: (event.clientY - box.top) / box.height}
          sync()
        }, options)
        stage.addEventListener("pointerleave", () => { pointer = null; sync() }, options)
        stage.addEventListener("focusin", () => sync(keyed()), options)
        // A theme switch repaints the ground at once; only the light itself eases.
        const repaint = () => { paint(); sync(true) }
        const theme = new MutationObserver(repaint)
        theme.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
        const scheme = matchMedia("(prefers-color-scheme: dark)")
        scheme.addEventListener("change", repaint)
        this.sync = () => { paint(); sync(keyed()) }
        // The swirl turns the light green and leads it; a point outside the frame lets go.
        this.follow = at => {
          const box = root.getBoundingClientRect()
          if (box.width === 0 || box.height === 0) return
          paint()
          renderer()?.aim({x: at.x / box.width, y: at.y / box.height, glow: GLOW + HOVER_GLOW}, true)
          nudge()
        }
        onReady(repaint)
        return () => {
          events.abort()
          theme.disconnect()
          scheme.removeEventListener("change", repaint)
          this.sync = undefined
          this.follow = undefined
        }
      },
    })
    this.controller.mount()
    this.handleEvent("stake-light", ({from}) => {
      const source = typeof from === "string" ? document.getElementById(from) : null
      // The Stake button the page has just opened, or the Stake tab while it is not showing.
      const button = stage.querySelector<HTMLElement>("[data-stake-button]")
      const target = button?.offsetParent ? button : stage.querySelector<HTMLElement>("[role='tab'][data-tab='stake']")
      const layer = stage.querySelector<HTMLElement>(".stake-light-layer")
      if (!source || !target || !layer || !stage.contains(source) || still(root)) return
      const box = stage.getBoundingClientRect()
      const path = {from: middle(source, box), to: middle(target, box)}
      const glow = (trail: number) => {
        const el = document.createElement("span")
        el.className = "stake-light"
        el.dataset.trail = String(trail)
        el.setAttribute("aria-hidden", "true")
        layer.append(el)
        return el
      }
      const glows = Array.from({length: TRAIL}, (_, i) => glow(i))
      const note = stage.querySelector<HTMLElement>("[data-fee-note]")
      if (note) play(note, {opacity: [0, 0, 1], duration: SWIRL + 200, ease: "linear"})
      root.dataset.swirl = "true"
      const progress = {t: 0}
      animate(progress, {
        t: 1,
        duration: SWIRL,
        ease: EASE_IN_OUT,
        onUpdate: () => {
          glows.forEach((glow, i) => {
            const t = Math.max(0, progress.t - i * .03)
            const at = swirlAt(path, t)
            utils.set(glow, {x: at.x, y: at.y, opacity: t === 0 ? 0 : 1 - i / TRAIL})
          })
          this.follow?.(swirlAt(path, progress.t))
        },
        onComplete: () => {
          glows.forEach(el => el.remove())
          delete root.dataset.swirl
          this.sync?.()
          // The light lands in the tab and spreads out.
          const landed = glow(0)
          utils.set(landed, {x: path.to.x, y: path.to.y})
          animate(landed, {scale: [1, 3.5], opacity: [1, 0], duration: SLOW * 1.5, ease: EASE_OUT, onComplete: () => landed.remove()})
        },
      })
    })
    const colors = matchMedia("(forced-colors: active)")
    const syncMotion = () => {
      if (still(root) || colors.matches) this.controller?.pause()
      else this.controller?.resume()
    }
    colors.addEventListener("change", syncMotion)
    this.release = () => colors.removeEventListener("change", syncMotion)
    syncMotion()
  },
  updated(this: LightHook) { this.sync?.() },
  disconnected(this: LightHook) { this.controller?.pause() },
  reconnected(this: LightHook) { if (!still(this.el) && !matchMedia("(forced-colors: active)").matches) this.controller?.resume() },
  destroyed(this: LightHook) { this.release?.(); this.controller?.destroy() },
}
