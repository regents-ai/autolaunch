import type {Hook} from "../hook_composition"

type LaunchDraftHook = Hook & {
  el: HTMLElement
  defaultTreasury?: () => void
  treasuryTouched?: (event: Event) => void
  patchedForm?: () => void
}

/** Historical pure helpers remain exported for the locked unit-test contract.
 * The hook no longer invokes them: signer selection must never write custody.
 */
type Ownership = {saved: string | undefined; filled: string | null; touched: boolean}

const treasuryField = 'input[name="launch_draft[treasury]"]'
const walletStateEvent = "autolaunch:wallet-state"

/**
 * The address a blank draft's Treasury should start as, or `null` to leave the
 * field exactly as it is.
 *
 * The default is an ordinary starting value, not a decision. It fills an empty
 * field and refreshes one still holding what it filled last, so switching wallet
 * before typing follows the selection. Once the field belongs to the customer,
 * nothing writes it again, however the selected wallet changes afterwards.
 */
export function defaultedTreasury(
  current: string,
  wallet: string | null,
  {filled, touched}: Ownership,
): string | null {
  if (!wallet || touched || current === wallet) return null
  return current === "" || current === filled ? wallet : null
}

/**
 * Who the field belongs to once the server has re-rendered the form.
 *
 * A saved-draft count that moved means the save went through and the server
 * cleared the form, so the next draft starts over from the wallet selected now.
 * Any other form carrying errors is one the server sent back with what was
 * submitted, and every address on it is the customer's — including one that
 * still reads exactly like the default.
 */
export function ownershipAfterPatch(
  ownership: Ownership,
  saved: string | undefined,
  errors: boolean,
): Ownership {
  if (saved !== ownership.saved) return {saved, filled: null, touched: false}
  return errors ? {...ownership, touched: true} : ownership
}

export const AutolaunchLaunchDraft: Hook = {
  mounted(this: LaunchDraftHook) {
    let ownership: Ownership = {saved: this.el.dataset.savedDrafts, filled: null, touched: false}

    // Kept as a stable listener target for hook teardown. Deliberately does
    // nothing: the active signer and immutable treasury are separate choices.
    this.defaultTreasury = () => undefined

    // Any edit hands the field over, including clearing it and retyping the very
    // address the default put there.
    this.treasuryTouched = ({target}) => {
      if ((target as Element).matches(treasuryField)) ownership = {...ownership, touched: true}
    }

    this.el.addEventListener("input", this.treasuryTouched)

    this.patchedForm = () => {
      ownership = ownershipAfterPatch(
        ownership,
        this.el.dataset.savedDrafts,
        this.el.dataset.draftErrors === "true",
      )
    }

    window.addEventListener(walletStateEvent, this.defaultTreasury)
  },

  updated(this: LaunchDraftHook) {
    this.patchedForm?.()
  },

  destroyed(this: LaunchDraftHook) {
    if (this.defaultTreasury) {
      window.removeEventListener(walletStateEvent, this.defaultTreasury)
    }

    if (this.treasuryTouched) {
      this.el.removeEventListener("input", this.treasuryTouched)
    }
  },
}
