import "phoenix_html"

import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import topbar from "../vendor/topbar"

import { installPinnedHeerich } from "../../../packages/regent_ui/assets/js/regent"
import { hooks } from "./hooks/index"

function readCsrfToken(): string {
  return document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() ?? ""
}

installPinnedHeerich()

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: readCsrfToken() },
  hooks,
})

topbar.config({ barColors: { 0: "#0ea5e9" }, shadowColor: "rgba(1, 9, 20, 0.35)" })
window.addEventListener("phx:page-loading-start", () => topbar.show(300))
window.addEventListener("phx:page-loading-stop", () => topbar.hide())

liveSocket.connect()

const globalWindow = window as Window & { liveSocket?: unknown }
globalWindow.liveSocket = liveSocket
