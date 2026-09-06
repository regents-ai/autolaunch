import "../css/app.css"

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/autolaunch"

import {
  browserCsrfToken,
  holdSocketDuringCookieRotation,
  installAccountAuthLazyLoader,
  installCrossTabCsrf,
  type PinnedSocket,
} from "./auth_lazy"
import {AutolaunchBidWallet} from "./hooks/autolaunch_bid_wallet"
import {AutolaunchLaunchDraft} from "./hooks/autolaunch_launch_draft"
import {AutolaunchLaunchWallet} from "./hooks/autolaunch_launch_wallet"
import {AutolaunchSubjectWallet} from "./hooks/autolaunch_subject_wallet"
import {XConnections} from "./hooks/x_connections"
import {Optics} from "./optics_controller.js"
import {installPublicTools} from "./public_tools"

const hooks = {
  ...colocatedHooks,
  AutolaunchBidWallet,
  AutolaunchLaunchDraft,
  AutolaunchLaunchWallet,
  AutolaunchSubjectWallet,
  Optics,
  XConnections,
}
if (!browserCsrfToken()) throw new Error("Missing CSRF token")

// Sign in and refresh renew the session and rotate its CSRF state, so every
// connection and reconnection reads the token the browser holds now.
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({_csrf_token: browserCsrfToken()}),
  hooks,
})

// Installed before the first connect, so even the page's opening attempt is
// subject to the barrier. `types.d.ts` describes only the LiveSocket surface
// this application calls, so the transport entry point is named at the cast.
holdSocketDuringCookieRotation(liveSocket.getSocket() as PinnedSocket)
liveSocket.connect()
installAccountAuthLazyLoader()
installCrossTabCsrf()
installPublicTools()

// Exposed for the browser console: liveSocket.enableDebug(), enableLatencySim().
window.liveSocket = liveSocket
