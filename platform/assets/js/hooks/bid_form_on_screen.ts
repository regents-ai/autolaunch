/**
 * The bid form a panel names in `data-press-form`, read at the moment of a
 * press. A review the server built for other values is never sent: the panel
 * asks for one built for exactly what is on screen instead.
 */

/** The form's fields as the server kept them when it built a review. */
export type BidInputs = {
  amount: string
  at_price: boolean
  limit_mode: string
  limit: string
  pay_with: string | null
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

/** Whether a review built for `inputs` is the bid these fields describe, read as BidForm.values/2 reads them. */
export function builtFor(inputs: BidInputs | undefined, params: Record<string, string>): boolean {
  if (!inputs) return false

  return (
    inputs.amount === (params.amount ?? "").trim() &&
    inputs.at_price === (params.at_price === "true") &&
    inputs.limit_mode === (params.limit_mode === "price" ? "price" : "fdv") &&
    inputs.limit === (params.limit ?? "").trim() &&
    (params.pay_with === undefined || inputs.pay_with === params.pay_with)
  )
}
