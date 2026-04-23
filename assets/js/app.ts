import "phoenix_html"

import { Heerich } from "heerich"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import topbar from "../vendor/topbar"

import { installHeerich } from "./regent"
import { hooks } from "./hooks/index"

function readCsrfToken(): string {
  return document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content?.trim() ?? ""
}

installHeerich(Heerich)

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: readCsrfToken() },
  hooks,
})

topbar.config({ barColors: { 0: "#0b7a4b" }, shadowColor: "rgba(24, 59, 51, 0.28)" })
window.addEventListener("phx:page-loading-start", () => topbar.show(300))
window.addEventListener("phx:page-loading-stop", () => topbar.hide())

liveSocket.connect()

const globalWindow = window as Window & { liveSocket?: unknown }
globalWindow.liveSocket = liveSocket
