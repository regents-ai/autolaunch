import type {Hook} from "../hook_composition"
import type {Painter} from "../optics/price_chart"

type PriceLineHook = Hook & {
  el: HTMLElement
  painter?: Promise<Painter | undefined>
  served?: string
  form?: HTMLFormElement
  follow?: (event: Event) => void
}

const cents = new Intl.NumberFormat("en-US", {minimumFractionDigits: 2, maximumFractionDigits: 2})

/**
 * A typed dollar price as the server reads one (`CoveredCallsFormat.parse_usd/1`):
 * one optional `$`, digits with at most one dot, to the cent, above nothing.
 */
export function typedPrice(text: string): number | null {
  const match = /^(\d*)(?:\.(\d*))?$/.exec(text.trim().replace(/^\$/, ""))
  if (!match) return null
  const [, whole, fraction = ""] = match
  if (whole + fraction === "" || fraction.replace(/0+$/, "").length > 2) return null
  const price = Number(`${whole || "0"}.${fraction || "0"}`)
  return price > 0 ? price : null
}

// Level `index` at `price`, its figure written as the page writes dollars;
// none when the price is null.
function setLevel(root: HTMLElement, index: number, price: number | null) {
  const level = root.querySelectorAll<HTMLElement>("[data-level]")[index]
  level.dataset.level = price === null ? "" : String(price)
  level.querySelector("[data-figure]")!.textContent = price === null ? "" : `$${cents.format(price)}`
}

function setLevels(root: HTMLElement, prices: (number | null)[]) {
  prices.forEach((price, index) => setLevel(root, index, price))
}

// The strike the person has just chosen in the Sell form: a suggestion's own
// price, or what the custom field holds once Custom is pressed or the field
// typed in. Undefined for any other press or field, and for Custom pressed
// over an empty field, which the server fills with the strike already chosen.
function chosen(form: HTMLFormElement, event: Event): number | null | undefined {
  const custom = form.elements.namedItem("custom") as HTMLInputElement
  const target = event.target as Element
  if (event.type === "input") return target === custom ? typedPrice(custom.value) : undefined
  const pill = target.closest<HTMLElement>("[data-strike]")
  if (!pill) return undefined
  if (pill.dataset.strike !== "custom") return Number(pill.dataset.strike)
  return typedPrice(custom.value) ?? undefined
}

// A covered-call ticket's price line: the stock's last 30 days, with the
// strike (and on Buy the break-even) drawn flat across it. WebGPU loads only
// on a page that shows one; a browser without it keeps the caption and the
// empty box. The server sends the levels; on Sell the strike's level also
// follows the form, so it moves the moment a strike is chosen or typed, before
// the server answers. While the custom strike is being typed, its own value
// is newer than any answer still on its way, so the server's is left aside.
export const PriceLine = {
  mounted(this: PriceLineHook) {
    this.served = this.el.dataset.levels!
    setLevels(this.el, JSON.parse(this.served) as (number | null)[])

    const form = this.el.dataset.follow && document.getElementById(this.el.dataset.follow)
    if (form instanceof HTMLFormElement) {
      this.form = form
      this.follow = event => {
        const strike = chosen(form, event)
        if (strike === undefined) return
        setLevel(this.el, 0, strike)
        void this.painter?.then(painter => painter?.update())
      }
      form.addEventListener("click", this.follow)
      form.addEventListener("input", this.follow)
    }

    this.painter = import("../optics/price_chart")
      .then(({paint}) => paint(this.el))
      .catch(() => undefined)
  },
  updated(this: PriceLineHook) {
    const levels = this.el.dataset.levels!
    const typing = this.form && document.activeElement === this.form.elements.namedItem("custom")
    if (levels !== this.served && !typing) setLevels(this.el, JSON.parse(levels) as (number | null)[])
    this.served = levels
    void this.painter?.then(painter => painter?.update())
  },
  destroyed(this: PriceLineHook) {
    if (this.form && this.follow) {
      this.form.removeEventListener("click", this.follow)
      this.form.removeEventListener("input", this.follow)
    }
    void this.painter?.then(painter => painter?.dispose())
  },
}
