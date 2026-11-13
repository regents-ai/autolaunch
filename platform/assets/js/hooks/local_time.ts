import type {Hook} from "../hook_composition"

type LocalTimeHook = {el: HTMLTimeElement}

// A time the server writes in UTC, shown in the reader's own time zone, with
// the UTC time beside it once the two differ. A patch from the server puts
// the UTC words back, so each update shows the local time again. A time past
// the last day a calendar names carries no `datetime` and keeps its words.
function showLocal(el: HTMLTimeElement) {
  const at = new Date(el.dateTime)
  if (Number.isNaN(at.getTime()) || at.getTimezoneOffset() === 0) return

  el.textContent = at.toLocaleString([], {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  })
  el.dataset.local = ""
}

export const LocalTime: Hook = {
  mounted(this: LocalTimeHook) {
    showLocal(this.el)
  },

  updated(this: LocalTimeHook) {
    showLocal(this.el)
  },
}
