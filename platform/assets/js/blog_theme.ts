// The market continues to follow the OS. Editorial pages have an explicit,
// persisted reading preference, without changing the market's theme behavior.
const control = document.querySelector<HTMLButtonElement>("[data-autolaunch-blog-theme]")
if (control) {
  const sync = () => {
    const light = document.documentElement.dataset.theme === "light"
    const current = light ? "Light" : "Dark"
    const next = light ? "Dark" : "Light"
    control.setAttribute("aria-pressed", String(light))
    control.setAttribute("aria-label", `Color theme: ${current}. Activate ${next} theme.`)
    control.title = `Switch to ${next}`
    const state = control.querySelector("[data-theme-toggle-state]")
    if (state) state.textContent = `${current} theme active`
  }
  control.addEventListener("click", () => {
    const next = document.documentElement.dataset.theme === "light" ? "dark" : "light"
    document.documentElement.dataset.theme = next
    try { localStorage.setItem("autolaunch-blog-theme", next) } catch {}
    sync()
  })
  new MutationObserver(sync).observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  sync()
}
export {}
