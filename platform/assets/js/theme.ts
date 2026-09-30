// The colour theme. Until the visitor chooses, the page carries no theme and the
// shared colours follow the device, dark unless it asks for light. A press
// chooses the opposite of the theme showing and writes it to the cookie the
// server reads, so the next page is drawn in it. The switch names the theme
// showing by itself, so nothing here rewrites its words.
const themeCookie = "regent_theme"
const themeMaxAge = 60 * 60 * 24 * 365
type Theme = "light" | "dark"
const themeColors: Record<Theme, string> = {dark: "#0e0e0e", light: "#e5e3d2"}

function chosenTheme(): Theme | undefined {
  const prefix = `${themeCookie}=`
  const value = document.cookie
    .split("; ")
    .find(cookie => cookie.startsWith(prefix))
    ?.slice(prefix.length)

  return value === "light" || value === "dark" ? value : undefined
}

function showingTheme(): Theme {
  const theme = document.documentElement.dataset.theme
  if (theme === "light" || theme === "dark") return theme
  return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"
}

// Live navigation keeps the document, so each page restates the visitor's
// choice, or none so the device decides.
function syncTheme() {
  const root = document.documentElement
  const theme = chosenTheme()
  if (theme) root.dataset.theme = theme
  else delete root.dataset.theme
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", theme ?? "dark light")
  document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]').forEach(meta => {
    meta.content = themeColors[theme ?? (meta.media.includes("light") ? "light" : "dark")]
  })
}

export function installTheme() {
  document.addEventListener("click", event => {
    if (!(event.target instanceof Element) || !event.target.closest("[data-theme-toggle]")) return

    const theme: Theme = showingTheme() === "dark" ? "light" : "dark"
    const secure = window.location.protocol === "https:" ? "; Secure" : ""
    document.cookie = `${themeCookie}=${theme}; Path=/; Max-Age=${themeMaxAge}; SameSite=Lax${secure}`
    syncTheme()
  })

  window.addEventListener("phx:page-loading-stop", syncTheme)
  window.addEventListener("popstate", syncTheme)
  window.addEventListener("pageshow", syncTheme)
}
