import {describe, expect, it} from "vitest"

import {browserCsrfToken, csrfMetaSelector} from "../js/csrf"

const documentWith = (content: string | null) => ({
  querySelector: (selectors: string) =>
    selectors === csrfMetaSelector ? {getAttribute: () => content} : null,
})

describe("browser csrf token", () => {
  it("reads the token the server stamped into the document head", () => {
    expect(browserCsrfToken(documentWith("a-token"))).toBe("a-token")
  })

  it("refuses a document whose head carries no token", () => {
    expect(() => browserCsrfToken({querySelector: () => null})).toThrow(/no csrf-token/)
  })

  it("refuses a token tag with an empty value", () => {
    expect(() => browserCsrfToken(documentWith(""))).toThrow(/no csrf-token/)
  })
})
