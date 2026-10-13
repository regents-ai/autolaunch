defmodule AutolaunchWeb.Components.MinimumWarning do
  @moduledoc """
  The one line that names an auction's minimum: shown from 30 minutes before
  bidding is due to end, and only while the bids are short of the minimum
  (`Autolaunch.AuctionFigures.minimum_warning_from/1`). An open page shows it
  when that moment arrives, with nothing new from the server.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :from, :any, required: true, doc: "when to start showing it; nothing is drawn for nil"
  attr :tag, :string, default: "span"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def minimum_warning(assigns) do
    ~H"""
    <.dynamic_tag
      :if={@from}
      tag_name={@tag}
      id={@id}
      class={@class}
      phx-hook=".MinimumWarning"
      data-from={DateTime.to_iso8601(@from)}
      hidden={DateTime.before?(DateTime.utc_now(), @from)}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MinimumWarning">
      // Shows the line once its moment arrives; a timer can wait at most about 24 days.
      export default {
        mounted() { this.arm() },
        updated() { this.arm() },
        destroyed() { clearTimeout(this.timer) },
        arm() {
          clearTimeout(this.timer)
          const wait = Date.parse(this.el.dataset.from) - Date.now()
          this.el.hidden = wait > 0
          if (wait > 0) this.timer = setTimeout(() => this.arm(), Math.min(wait, 2 ** 31 - 1))
        }
      }
    </script>
    """
  end
end
