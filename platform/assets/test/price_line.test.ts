import {expect, it} from "vitest"

import {typedPrice} from "../js/hooks/price_line"

// The line takes a typed strike as the server reads one
// (`CoveredCallsFormat.parse_usd/1`), so it never moves to a strike the
// ticket then refuses.
it("a typed strike moves the line only when the server would read it as a price", () => {
  const read: [string, number | null][] = [
    ["270", 270],
    ["$270.5", 270.5],
    [" 270.50 ", 270.5],
    ["270.500", 270.5],
    [".5", 0.5],
    ["5.", 5],
    ["270.505", null],
    ["0", null],
    ["0.00", null],
    [".", null],
    ["", null],
    ["$", null],
    ["1,000", null],
    ["-5", null],
    ["2e3", null],
    ["abc", null],
  ]

  for (const [text, price] of read) expect(typedPrice(text), text).toBe(price)
})
