/**
 * Motion for things the server decides: a list that changes, such as a stack
 * of notes, a figure that moves, a refusal and a tick for something just done.
 * The page renders every result first; these islands only animate from the
 * old picture to the new one.
 */
import {
  animate,
  createLayout,
  createScope,
  spring,
  splitText,
  stagger,
  type AnimationParams,
  type LayoutAnimationParams,
  type Scope,
  type TextSplitter,
} from "animejs"
import {BASE, CLIPPED_CHAR, EASE_OUT, SLOW, play, rest, still, watched} from "./shared"
import {deny} from "./press"
import type {Hook} from "../../hook_composition"

// How a list moves when the server adds, reorders or drops its items: `bounce`
// for lists and `pop` for notes that come and go. A new item only fades in
// where it lands: a slide or a scale in its entrance stays written on it as
// `translate: none` once it settles. Each is built fresh per change because a
// stagger remembers the items it measured.
export const LAYOUTS: Record<string, () => LayoutAnimationParams> = {
  bounce: () => ({
    ease: spring({bounce: 0.35, duration: 420}),
    enterFrom: {opacity: 0},
    leaveTo: {opacity: 0, transform: "scale(.9)", ease: "in(3)", duration: BASE},
  }),
  pop: () => ({
    ease: spring({bounce: 0.45, duration: 360}),
    enterFrom: {opacity: 0},
    leaveTo: {opacity: 0, transform: "scale(.8)", ease: "in(3)", duration: BASE},
  }),
}

type ListHook = {el: HTMLElement; scope?: Scope}

/**
 * A list the server owns, built from a table of versions. It renders
 * `data-layout-id` on the list and on every item, names the items in
 * `data-children` and the version in `data-variant`. An item that is leaving
 * is hidden for a moment before the server drops it, so it can fade out while
 * its neighbours close the gap.
 */
export const listHook = (layouts: Record<string, () => LayoutAnimationParams>): Hook => ({
  mounted(this: ListHook) {
    const scope = createScope({root: this.el})

    this.scope = scope.add(() => {
      const layout = createLayout(this.el, {children: this.el.dataset.children})
      scope.add("record", () => layout.record())
      scope.add("move", () => layout.animate(layouts[this.el.dataset.variant ?? ""]()))
    })
  },

  beforeUpdate(this: ListHook) {
    this.scope?.methods.record()
  },

  updated(this: ListHook) {
    if (!still(this.el)) this.scope?.methods.move()
  },

  destroyed(this: ListHook) {
    this.scope?.revert()
  },
})

export const MotionList = listHook(LAYOUTS)

// How the digits that changed arrive. `clip` masks each digit in its own
// slot, so a digit rolling in is hidden until it reaches the slot.
export type Roll = {clip: boolean; move: (up: boolean) => AnimationParams}

export const ROLLS: Record<string, Roll> = {
  roll: {clip: true, move: up => ({y: [up ? "100%" : "-100%", "0%"], duration: SLOW, ease: "outBack(1.4)"})},
  // A balance that changed while the reader watches: the new digits flash in.
  flash: {clip: false, move: () => ({opacity: [0, 1, 0.35, 1], scale: [1.35, 1], duration: SLOW * 3, ease: "outQuad"})},
}

// What a figure is worth, decimals included, so 1.75 to 2 rolls up.
const worth = (text: string) => Number(text.replace(/[^\d.]/g, ""))

// A figure's characters as the split makes them, which leaves out spaces, so
// a figure with a unit such as "12.5 USDC" lines up digit for digit.
const glyphs = (figure: HTMLElement) => (figure.textContent ?? "").replace(/\s/g, "")

// The figures inside a part of the page, each marked `data-count`.
const figures = (root: HTMLElement) => [...root.querySelectorAll<HTMLElement>("[data-count]")]

type CountHook = {el: HTMLElement; scope?: Scope; before?: string[]; splits: Set<TextSplitter>}

// Put the plain figure back, but only for a split that is still on the page:
// an older one would write its stale figure over the new one.
function join(hook: CountHook, split: TextSplitter) {
  if (!hook.splits.delete(split)) return
  split.revert()
}

/**
 * Figures the server changes, built from a table of versions. A figure may
 * carry a unit, such as "12.5 USDC". Only the characters that changed move,
 * the ones nearest the end first, like a counter turning over. The figure is
 * split into pieces for the move and joined back as soon as it ends, so the
 * page always patches the plain figure it rendered. A figure that changed
 * while the connection was away simply shows its new value when it comes back.
 */
export const countHook = (rolls: Record<string, Roll>): Hook => ({
  mounted(this: CountHook) {
    const scope = createScope({root: this.el})
    this.splits = new Set()

    this.scope = scope.add(() => {
      scope.add("roll", (split: TextSplitter, digits: HTMLElement[], up: boolean) => {
        animate(digits, {
          ...rolls[this.el.dataset.variant ?? ""].move(up),
          delay: stagger(45, {from: "last"}),
          onComplete: () => join(this, split),
        })
      })
    })
  },

  beforeUpdate(this: CountHook) {
    for (const split of this.splits) join(this, split)
    this.before = figures(this.el).map(glyphs)
  },

  updated(this: CountHook) {
    const before = this.before ?? []
    const after = figures(this.el)
    if (still(this.el) || !watched(this.el) || after.length !== before.length) return

    const {clip} = rolls[this.el.dataset.variant ?? ""]
    after.forEach((figure, index) => {
      const was = before[index]
      const now = glyphs(figure)
      if (was === now) return

      const split = splitText(figure, {words: false, chars: clip ? CLIPPED_CHAR : true})
      const digits = split.chars.filter((_char, i) => was.at(i - now.length) !== now[i])
      this.splits.add(split)
      this.scope?.methods.roll(split, digits, worth(now) > worth(was))
    })
  },

  destroyed(this: CountHook) {
    for (const split of this.splits) join(this, split)
    this.scope?.revert()
  },
})

export const MotionCount = countHook(ROLLS)

type RefusalHook = {el: HTMLElement; scope?: Scope; said?: string}

/**
 * A message a live page shows when it refuses something. It shakes once when
 * it appears and again whenever it says something new, while `data-refused`
 * is on it. A shake still playing when the message goes stops with it. Pages
 * the server draws once shake their alerts from `motion.ts`.
 */
export const MotionRefusal: Hook = {
  mounted(this: RefusalHook) {
    const scope = createScope({root: this.el})
    this.said = this.el.textContent ?? ""

    this.scope = scope.add(() => {
      scope.add("shake", () => {
        if (this.el.dataset.refused !== undefined) deny(this.el)
      })
      scope.methods.shake()
    })
  },

  updated(this: RefusalHook) {
    const said = this.el.textContent ?? ""
    if (said !== this.said) this.scope?.methods.shake()
    this.said = said
  },

  destroyed(this: RefusalHook) {
    this.scope?.revert()
  },
}

// A tick's stroke drawn in once, from its start to its end. Its path is one
// unit long (`pathLength="1"`) and one dash as long covers it (`.motion-tick`
// in components/motion.css), so the page renders it whole; the draw slides
// that dash in from just before the path's start, then hands the path back to
// the stylesheet.
export const drawTick = (path: Element, delay = 0) =>
  play(path, {strokeDashoffset: [1, 0], delay, duration: SLOW, ease: EASE_OUT})

// The line of the tick inside `el`, if it shows one.
const tickLine = (el: Element) => el.querySelector(".motion-tick path")

type TickHook = {el: HTMLElement}

/**
 * A tick (`AutolaunchWeb.Motion.tick/1`) that arrives with the news of
 * something just done. It draws itself in when it arrives on a live page; one
 * already there when the page opens or its connection comes back shows whole
 * and still. The page leaves its line's style alone while it draws, so an
 * update that lands mid-draw lets it finish.
 */
export const MotionTick: Hook = {
  mounted(this: TickHook) {
    if (watched(this.el) && !still(this.el)) drawTick(tickLine(this.el)!)
  },

  destroyed(this: TickHook) {
    rest(tickLine(this.el)!)
  },
}

type StepHook = {el: HTMLElement; done?: boolean}

/**
 * One step of a wallet review, whose mark is a tick once its `data-state` is
 * `done`. The tick draws itself in when a newer reading first shows the step
 * done while the reader watches. A step that is already done when it first
 * shows, when the page opens or when its connection comes back shows its tick
 * whole and still, and so does one drawn again or moved in the list. The page
 * leaves the tick's line alone while it draws, so an update that lands
 * mid-draw lets it finish.
 */
export const MotionStep: Hook = {
  beforeUpdate(this: StepHook) {
    this.done = this.el.dataset.state === "done"
  },

  updated(this: StepHook) {
    if (this.done || this.el.dataset.state !== "done") return
    if (watched(this.el) && !still(this.el)) drawTick(tickLine(this.el)!)
  },

  destroyed(this: StepHook) {
    const line = tickLine(this.el)
    if (line) rest(line)
  },
}
