import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {Countdown, closesIn} from "../js/hooks/countdown"

// The same cases as the server's words (`CoveredCallsFormat.closes_in/1`).
const words: [number, string][] = [
  [86_400, "Closes in 24 h"],
  [5 * 3600 + 59 * 60, "Closes in 5 h"],
  [3600, "Closes in 1 h"],
  [3599, "Closes in 59 min"],
  [61, "Closes in 1 min"],
  [30, "Closes in 1 min"],
  [0, "Closed"],
  [-5, "Closed"],
]

type Mounted = {el: HTMLElement; mounted(): void; updated(): void; destroyed(): void}

// The countdown on a stand-in element: the chain's time at the reading is
// `chainNow`, far from the device clock, and the window closes `left` later.
function countdown(chainNow: number, left: number): Mounted {
  const el = {dataset: {closes: String(chainNow + left), now: String(chainNow)}, textContent: ""}
  return Object.assign(Object.create(Countdown), {el}) as Mounted
}

describe("an exercise window's time left", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2031-01-01T00:00:00Z"))
  })

  afterEach(() => vi.useRealTimers())

  it("names whole hours from an hour up, minutes below, never under a minute until it closes", () => {
    for (const [seconds, said] of words) expect(closesIn(seconds)).toBe(said)
  })

  it("counts from the chain's time, not the device clock, and counts down as it runs", () => {
    const hook = countdown(1_778_400_000, 5 * 3600 + 30)
    hook.mounted()
    expect(hook.el.textContent).toBe("Closes in 5 h")

    vi.advanceTimersByTime(60_000)
    expect(hook.el.textContent).toBe("Closes in 4 h")

    vi.advanceTimersByTime(5 * 3600 * 1000)
    expect(hook.el.textContent).toBe("Closed")
    hook.destroyed()
  })

  it("carries on through a patch of the same reading and starts again from a new one", () => {
    const hook = countdown(1_778_400_000, 2 * 3600)
    hook.mounted()
    vi.advanceTimersByTime(30 * 60_000)

    hook.el.textContent = "Closes in 2 h"
    hook.updated()
    expect(hook.el.textContent).toBe("Closes in 1 h")

    // A new reading half an hour on, closing at the same moment.
    hook.el.dataset.now = String(1_778_400_000 + 1800)
    hook.updated()
    expect(hook.el.textContent).toBe("Closes in 1 h")
    vi.advanceTimersByTime(31 * 60_000)
    expect(hook.el.textContent).toBe("Closes in 59 min")
    hook.destroyed()
  })
})
