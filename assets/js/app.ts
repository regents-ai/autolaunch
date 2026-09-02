import "../css/app.css"

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/autolaunch"

import {browserCsrfToken} from "./csrf"

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: browserCsrfToken(document)},
  hooks: {...colocatedHooks},
})

liveSocket.connect()

// Exposed for the browser console: liveSocket.enableDebug(), enableLatencySim().
window.liveSocket = liveSocket
