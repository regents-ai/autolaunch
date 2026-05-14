import assert from "node:assert/strict"
import { afterEach, beforeEach, describe, it } from "node:test"

import { activeSectionForPath, ShellChrome, syncActiveShellRoute } from "./shell-chrome.ts"

class FakeClassList {
  private values = new Set<string>()

  add(...tokens: string[]) {
    tokens.forEach((token) => this.values.add(token))
  }

  remove(...tokens: string[]) {
    tokens.forEach((token) => this.values.delete(token))
  }

  contains(token: string) {
    return this.values.has(token)
  }
}

class FakeElement {
  dataset: Record<string, string> = {}
  textContent = ""
  classList = new FakeClassList()
  parent: FakeElement | null = null
  style = {} as CSSStyleDeclaration
  attributes: Record<string, string> = {}

  constructor(dataset: Record<string, string> = {}, textContent = "") {
    this.dataset = dataset
    this.textContent = textContent
  }

  closest<T extends FakeElement>(selector: string): T | null {
    let current: FakeElement | null = this

    while (current) {
      if (selector === "[data-copy-value]" && current.dataset.copyValue) {
        return current as T
      }

      if (
        selector === "[data-theme-action='toggle']" &&
          current.dataset.themeAction === "toggle"
      ) {
        return current as T
      }

      current = current.parent
    }

    return null
  }

  setAttribute(name: string, value: string) {
    this.attributes[name] = value
  }

  removeAttribute(name: string) {
    delete this.attributes[name]
  }
}

class FakeRoot extends FakeElement {
  private clickHandlers = new Set<(event: Event) => void>()
  navLinks: FakeElement[] = []

  addEventListener(eventName: string, handler: (event: Event) => void) {
    if (eventName === "click") this.clickHandlers.add(handler)
  }

  removeEventListener(eventName: string, handler: (event: Event) => void) {
    if (eventName === "click") this.clickHandlers.delete(handler)
  }

  contains(element: FakeElement | null): boolean {
    let current = element

    while (current) {
      if (current === this) return true
      current = current.parent
    }

    return false
  }

  querySelectorAll<T extends FakeElement>(selector: string): T[] {
    if (selector === "[data-nav-section]") return this.navLinks as T[]
    return []
  }

  click(target: FakeElement) {
    const event = { target } as unknown as Event
    this.clickHandlers.forEach((handler) => handler(event))
  }
}

class FakeCustomEvent<T> {
  type: string
  detail: T

  constructor(type: string, init?: { detail?: T }) {
    this.type = type
    this.detail = init?.detail as T
  }
}

const originalWindow = globalThis.window
const originalDocument = globalThis.document
const originalClipboard = globalThis.navigator?.clipboard
const originalHTMLElement = globalThis.HTMLElement
const originalSVGElement = globalThis.SVGElement
const originalCustomEvent = globalThis.CustomEvent

function mountShellChrome(root: FakeRoot) {
  const mounted = ShellChrome.mounted
  assert.ok(mounted, "ShellChrome.mounted must exist")
  mounted.call({ el: root } as never)
}

function destroyShellChrome(root: FakeRoot) {
  const destroyed = ShellChrome.destroyed
  assert.ok(destroyed, "ShellChrome.destroyed must exist")
  destroyed.call({ el: root } as never)
}

describe("shell-chrome hook", () => {
  let dispatchedEvents: Array<FakeCustomEvent<{ theme: string }>>
  let copiedValues: string[]

  beforeEach(() => {
    dispatchedEvents = []
    copiedValues = []

    globalThis.HTMLElement = FakeElement as unknown as typeof HTMLElement
    globalThis.SVGElement = FakeElement as unknown as typeof SVGElement
    globalThis.CustomEvent = FakeCustomEvent as unknown as typeof CustomEvent
    globalThis.document = {
      documentElement: {
        getAttribute(name: string) {
          return name === "data-theme" ? "light" : null
        },
      },
    } as unknown as Document
    globalThis.window = {
      matchMedia: () =>
        ({
          matches: true,
          media: "(prefers-reduced-motion: reduce)",
          onchange: null,
          addListener() {},
          removeListener() {},
          addEventListener() {},
          removeEventListener() {},
          dispatchEvent() {
            return true
          },
        }) as MediaQueryList,
      dispatchEvent(event: FakeCustomEvent<{ theme: string }>) {
        dispatchedEvents.push(event)
        return true
      },
      setTimeout,
      clearTimeout,
      location: { pathname: "/" },
    } as unknown as Window & typeof globalThis
    Object.defineProperty(globalThis.navigator, "clipboard", {
      configurable: true,
      value: {
        writeText(value: string) {
          copiedValues.push(value)
          return Promise.resolve()
        },
      },
    })
  })

  afterEach(() => {
    globalThis.window = originalWindow
    globalThis.document = originalDocument
    Object.defineProperty(globalThis.navigator, "clipboard", {
      configurable: true,
      value: originalClipboard,
    })
    globalThis.HTMLElement = originalHTMLElement
    globalThis.SVGElement = originalSVGElement
    globalThis.CustomEvent = originalCustomEvent
  })

  it("copies command text and restores the original label", async () => {
    const root = new FakeRoot()
    const button = new FakeElement({ copyValue: "regents autolaunch prelaunch wizard" }, "Copy command")
    button.parent = root

    mountShellChrome(root)
    root.click(button)

    assert.deepEqual(copiedValues, ["regents autolaunch prelaunch wizard"])
    assert.equal(button.textContent, "Copied")

    await new Promise((resolve) => setTimeout(resolve, 1450))
    assert.equal(button.textContent, "Copy command")
  })

  it("dispatches a theme change from the shell", () => {
    const root = new FakeRoot()
    const button = new FakeElement({ themeAction: "toggle" }, "Theme")
    button.parent = root

    mountShellChrome(root)
    root.click(button)

    assert.equal(dispatchedEvents.length, 1)
    assert.equal(dispatchedEvents[0]?.type, "autolaunch:set-theme")
    assert.deepEqual(dispatchedEvents[0]?.detail, { theme: "dark" })
  })

  it("removes the click handler on destroy", () => {
    const root = new FakeRoot()
    const button = new FakeElement({ copyValue: "regent" }, "Copy")
    button.parent = root

    mountShellChrome(root)
    destroyShellChrome(root)
    root.click(button)

    assert.deepEqual(copiedValues, [])
  })

  it("maps routes to the active sidebar section", () => {
    assert.equal(activeSectionForPath("/"), "home")
    assert.equal(activeSectionForPath("/docs"), "docs")
    assert.equal(activeSectionForPath("/auctions/auc_1"), "auctions")
    assert.equal(activeSectionForPath("/launch-via-agent"), "launch")
    assert.equal(activeSectionForPath("/ens-link"), "profile")
  })

  it("updates sidebar active state from the browser path", () => {
    const root = new FakeRoot()
    const launch = new FakeElement({ navSection: "launch" }, "Launch")
    const docs = new FakeElement({ navSection: "docs" }, "Docs")
    launch.classList.add("is-active")
    root.navLinks = [launch, docs]

    syncActiveShellRoute(root as unknown as HTMLElement, "/docs")

    assert.equal(launch.classList.contains("is-active"), false)
    assert.equal(docs.classList.contains("is-active"), true)
    assert.equal(docs.attributes["aria-current"], "page")
    assert.equal(launch.attributes["aria-current"], undefined)
  })
})
