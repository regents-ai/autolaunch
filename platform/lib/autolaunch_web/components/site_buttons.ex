defmodule AutolaunchWeb.Components.SiteButtons do
  @moduledoc """
  The ground a group of the site's main buttons stands on, as the template's
  study of the site's buttons has it: the soft light behind them (`SiteLight`)
  and the press their buttons make (`SiteButtons`, `assets/js/hooks/site_buttons.ts`).
  A button takes part by carrying `data-press="motion"`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :class, :any, default: nil

  attr :shape, :string,
    default: "pool",
    values: ~w(pool button),
    doc:
      "`pool`: a round light that follows the pointer. `button`: a light shaped like the button under the pointer, with keyboard focus or for the page you are on."

  attr :swirl, :boolean,
    default: false,
    doc: "Adds the layer the light swirls across after a claim, which page updates leave alone."

  slot :inner_block, required: true

  def stage(assigns) do
    ~H"""
    <div
      id={@id}
      class={["site-light-stage", @class]}
      phx-hook="SiteButtons"
      phx-mounted={JS.ignore_attributes("data-input")}
    >
      <div
        id={@id <> "-light"}
        class="site-light"
        data-light-shape={@shape}
        phx-hook="SiteLight"
        phx-update="ignore"
        phx-mounted={JS.ignore_attributes("data-light-ready")}
        aria-hidden="true"
      >
        <canvas data-light-canvas></canvas>
      </div>
      <div
        :if={@swirl}
        id={@id <> "-swirl"}
        class="stake-light-layer"
        phx-update="ignore"
        aria-hidden="true"
      >
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
