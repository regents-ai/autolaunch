// Ticks every countdown on the page from its own opening time. The server
// renders the first value and LiveView leaves the element alone afterwards,
// so one document-wide ticker also covers pages reached by live navigation.
export function installOpeningCountdown(): void {
  const pad = (value: number) => String(value).padStart(2, "0");

  const tick = () => {
    document.querySelectorAll<HTMLElement>("[data-opens-at]").forEach((countdown) => {
      const time = countdown.querySelector(".opening-countdown__time");
      const seconds = Math.max(
        Math.floor((Date.parse(countdown.dataset.opensAt ?? "") - Date.now()) / 1000),
        0
      );
      if (time) {
        time.textContent =
          `${pad(Math.floor(seconds / 3600))}:${pad(Math.floor((seconds % 3600) / 60))}:${pad(seconds % 60)}`;
      }
    });
    window.setTimeout(tick, 1000 - (Date.now() % 1000));
  };

  tick();
}
