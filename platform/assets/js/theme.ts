// The colour theme travels in a cookie so the server can render it before the
// first paint. The switch itself is client-owned: it writes the cookie, restyles
// the document, and re-announces itself after every live navigation.
const themeCookie = "regent_theme"
const themeMaxAge = 60 * 60 * 24 * 365
const themes = {
  light: {name: "Light", nextName: "Dark", color: "#e5e3d2"},
  dark: {name: "Dark", nextName: "Light", color: "#0e0e0e"},
}
type Theme = keyof typeof themes

const isTheme = (value: string | undefined): value is Theme =>
  value === "light" || value === "dark"

function readThemeCookie(): Theme {
  const prefix = `${themeCookie}=`
  const value = document.cookie
    .split("; ")
    .find(cookie => cookie.startsWith(prefix))
    ?.slice(prefix.length)

  return isTheme(value) ? value : "dark"
}

function writeThemeCookie(theme: Theme) {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  document.cookie =
    `${themeCookie}=${theme}; Path=/; Max-Age=${themeMaxAge}; SameSite=Lax${secure}`
}

function applyTheme(theme: Theme) {
  const selected = themes[theme]
  document.documentElement.dataset.theme = theme
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", theme)
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", selected.color)

  document.querySelectorAll<HTMLElement>("[data-theme-toggle]").forEach(toggle => {
    toggle.setAttribute("aria-pressed", String(theme === "light"))
    toggle.setAttribute("aria-label", `Color theme: ${selected.name}. Activate ${selected.nextName} theme.`)
    toggle.setAttribute("title", `Switch to ${selected.nextName}`)
    const state = toggle.querySelector("[data-theme-toggle-state]")
    if (state) state.textContent = `${selected.name} theme active`
  })
}

const syncTheme = () => applyTheme(readThemeCookie())

export function installTheme() {
  document.addEventListener("click", event => {
    if (!(event.target instanceof Element) || !event.target.closest("[data-theme-toggle]")) return

    const theme: Theme = document.documentElement.dataset.theme === "light" ? "dark" : "light"
    writeThemeCookie(theme)
    applyTheme(theme)
  })

  window.addEventListener("phx:page-loading-stop", syncTheme)
  window.addEventListener("popstate", syncTheme)
  window.addEventListener("pageshow", syncTheme)
  syncTheme()
}
