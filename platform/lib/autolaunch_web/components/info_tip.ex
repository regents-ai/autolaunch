defmodule AutolaunchWeb.Components.InfoTip do
  @moduledoc """
  A short explanation that opens over the page while the pointer is on its
  label or figure, while its info icon has keyboard focus, or when either is
  tapped. The box sits above what it explains, with an arrow pointing at it,
  and moves below when there is no room above. It opens in the browser's top
  layer, so a scrolling table or a card around it never cuts it off.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :icon, :boolean, default: true, doc: "false for a figure that opens the box itself"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def info_tip(assigns) do
    ~H"""
    <span
      id={@id}
      class={["info-tip", @class]}
      phx-hook=".InfoTip"
      aria-describedby={!@icon && "#{@id}-tip"}
    >
      {render_slot(@inner_block)}<button
        :if={@icon}
        type="button"
        class="info-tip__icon"
        aria-label="More about this"
        aria-describedby={"#{@id}-tip"}
      >i</button>
      <span id={"#{@id}-tip"} class="info-tip__panel" role="tooltip" popover="manual">{@text}</span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".InfoTip">
      export default {
        mounted() {
          this.tip = this.el.querySelector(".info-tip__panel")
          this.anchor = this.el.querySelector(".info-tip__icon") || this.el
          this.hide = () => this.tip.matches(":popover-open") && this.tip.hidePopover()
          this.away = (event) => { if (!this.el.contains(event.target)) this.hide() }
          this.el.addEventListener("pointerenter", (event) => { if (event.pointerType === "mouse") this.show() })
          this.el.addEventListener("pointerleave", (event) => { if (event.pointerType === "mouse") this.hide() })
          this.el.addEventListener("pointerup", (event) => {
            if (event.pointerType !== "mouse") this.tip.matches(":popover-open") ? this.hide() : this.show()
          })
          this.el.addEventListener("focusin", (event) => { if (event.target.matches(":focus-visible")) this.show() })
          this.el.addEventListener("focusout", this.hide)
          this.el.addEventListener("keydown", (event) => { if (event.key === "Escape") this.hide() })
          window.addEventListener("scroll", this.hide, { capture: true, passive: true })
          document.addEventListener("pointerdown", this.away)
        },
        destroyed() {
          window.removeEventListener("scroll", this.hide, { capture: true })
          document.removeEventListener("pointerdown", this.away)
        },
        show() {
          const tip = this.tip
          if (!tip.matches(":popover-open")) tip.showPopover()
          const at = this.anchor.getBoundingClientRect()
          const size = tip.getBoundingClientRect()
          const center = at.left + at.width / 2
          const left = Math.min(Math.max(center - size.width / 2, 8), window.innerWidth - size.width - 8)
          const above = at.top - size.height - 10 >= 8
          tip.dataset.side = above ? "top" : "bottom"
          tip.style.left = `${left}px`
          tip.style.top = `${above ? at.top - size.height - 10 : at.bottom + 10}px`
          tip.style.setProperty("--arrow-x", `${center - left}px`)
        }
      }
    </script>
    """
  end
end
