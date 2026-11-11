import type {Hook} from "../hook_composition"

type CountdownHook = {el: HTMLElement; base: number; at: number; timer?: ReturnType<typeof setInterval>}

/**
 * How long is left before `seconds` from now, in the words the server writes
 * (`AutolaunchWeb.CoveredCallsFormat.closes_in/1`).
 */
export function closesIn(seconds: number): string {
  if (seconds <= 0) return "Closed"
  if (seconds >= 3600) return `Closes in ${Math.floor(seconds / 3600)} h`
  return `Closes in ${Math.max(Math.floor(seconds / 60), 1)} min`
}

// The time left, from the chain's time at the reading (`data-now`) plus what
// the reader's clock has counted since, so a device clock set wrong does not
// move it.
function tick(hook: CountdownHook) {
  const elapsed = (Date.now() - hook.at) / 1000
  hook.el.textContent = closesIn(Number(hook.el.dataset.closes) - hook.base - elapsed)
}

function anchor(hook: CountdownHook) {
  hook.base = Number(hook.el.dataset.now)
  hook.at = Date.now()
  tick(hook)
}

/**
 * An exercise window's time left, counted down every half minute. A patch
 * puts the server's words back: a new reading starts the count again from
 * its time, the same reading carries on.
 */
export const Countdown: Hook = {
  mounted(this: CountdownHook) {
    anchor(this)
    this.timer = setInterval(() => tick(this), 30_000)
  },

  updated(this: CountdownHook) {
    if (Number(this.el.dataset.now) === this.base) tick(this)
    else anchor(this)
  },

  destroyed(this: CountdownHook) {
    clearInterval(this.timer)
  },
}
