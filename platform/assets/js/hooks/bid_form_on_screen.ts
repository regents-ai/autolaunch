/**
 * The bid form a panel names in `data-press-form`, read at the moment of a
 * press. A review the server built for other values is never sent: the panel
 * asks for one built for exactly what is on screen instead.
 */

/** The form's fields as the server kept them when it built a review. */
export type BidInputs = {
  amount: string
  pay_with: string | null
  basis: string
  stop: number
  fdv: string
  price: string
}

/** The fields exactly as the form would submit them, or null when the panel shows no form. */
export function formOnScreen(panel: HTMLElement): Record<string, string> | null {
  const id = panel.dataset.pressForm
  const form = id ? document.getElementById(id) : null
  if (!(form instanceof HTMLFormElement)) return null

  // The last value of a repeated name wins, as it does on the server.
  const params: Record<string, string> = {}
  for (const [name, value] of new FormData(form)) {
    if (typeof value === "string") params[name] = value
  }
  return params
}

const trimmed = (value: string | undefined) => (value ?? "").trim()

/**
 * What sets the bid's limit, read as BidForm.values/3 reads it: the slider or
 * the FDV box when either differs from what it last showed, else the basis the
 * server kept.
 */
function basis(params: Record<string, string>): string {
  if (params.stop !== params.stop_shown) return "stop"
  if (trimmed(params.fdv) !== trimmed(params.fdv_shown)) return "fdv"
  return ["stop", "fdv", "price"].includes(params.basis) ? params.basis : "stop"
}

/** Whether a review built for `inputs` is the bid these fields describe. */
export function builtFor(inputs: BidInputs | undefined, params: Record<string, string>): boolean {
  if (!inputs) return false

  const onScreen = basis(params)
  const limit =
    onScreen === "stop"
      ? String(inputs.stop) === params.stop
      : onScreen === "fdv"
        ? inputs.fdv === trimmed(params.fdv)
        : inputs.price === trimmed(params.price)

  return (
    inputs.amount === trimmed(params.amount) &&
    (params.pay_with === undefined || inputs.pay_with === params.pay_with) &&
    inputs.basis === onScreen &&
    limit
  )
}
