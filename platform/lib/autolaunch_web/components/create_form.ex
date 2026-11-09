defmodule AutolaunchWeb.Components.CreateForm do
  @moduledoc """
  The parts both Create pages are built from: a fold (a titled row with an
  icon that opens to its fields), a menu (a button that opens a short list of
  choices), the Socials rows shown before sign-in, and the summary card that
  stays beside the form with the launch button under it.
  """
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.XConnections, only: [connection: 1]

  alias Autolaunch.StoredImage
  alias AutolaunchWeb.Components.MarketCard

  attr :id, :string, required: true
  attr :icon, :string, required: true, doc: "the Lucide name"
  attr :title, :string, required: true
  attr :open, :boolean, default: false, doc: "open when the page first draws it"
  slot :inner_block, required: true

  @doc "A titled row that opens to its fields. It stays as the person leaves it through page updates."
  def fold(assigns) do
    ~H"""
    <details
      id={@id}
      class="create-fold"
      open={@open}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="create-fold__head">
        <span class="create-fold__icon"><Regent.Icons.icon name={@icon} /></span>
        <span class="create-fold__title">{@title}</span>
        <Regent.Icons.icon name="chevron-down" class="create-fold__chevron" />
      </summary>
      <div class="create-fold__body">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :current, required: true, doc: "the chosen option, on the button"

  slot :inner_block,
    required: true,
    doc: "the options: buttons that close the menu themselves, or radio labels"

  @doc """
  A labelled button that opens a short list of choices under it. A press
  outside the menu, or Escape, closes it. A radio option picked with the
  pointer, or with Enter, closes it too; arrow keys move the choice and leave
  it open.
  """
  def menu(assigns) do
    ~H"""
    <div
      id={@id}
      class="create-menu"
      phx-hook="MotionPanels"
      phx-click-away={close_menu(@id)}
      phx-window-keydown={close_menu(@id)}
      phx-key="Escape"
    >
      <span id={"#{@id}-label"} class="create-page__label">{@label}</span>
      <button
        type="button"
        id={"#{@id}-button"}
        class="create-menu__button"
        aria-haspopup="true"
        aria-expanded="false"
        aria-controls={"#{@id}-list"}
        aria-labelledby={"#{@id}-label #{@id}-button"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        phx-click={toggle_menu(@id)}
      >
        {render_slot(@current)}
        <Regent.Icons.icon name="chevron-down" class="create-menu__chevron" />
      </button>
      <div
        id={"#{@id}-list"}
        class="create-menu__list"
        hidden
        phx-hook=".CreateMenu"
        data-close={close_menu(@id)}
        data-button={"#{@id}-button"}
        {AutolaunchWeb.Motion.panel("menu", ["hidden"])}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CreateMenu">
      // A radio option picked with the pointer closes the menu; arrow keys
      // move the choice without closing it, and Enter on one closes it and
      // returns to the button instead of sending the form.
      export default {
        mounted() {
          this.el.addEventListener("click", event => {
            if (event.detail > 0 && event.target.closest("label")) this.js().exec(this.el.dataset.close)
          })
          this.el.addEventListener("keydown", event => {
            if (event.key === "Enter" && event.target.type === "radio") {
              event.preventDefault()
              this.js().exec(this.el.dataset.close)
              document.getElementById(this.el.dataset.button).focus()
            }
          })
        }
      }
    </script>
    """
  end

  @doc "Closes the menu `id`, for an option's own press."
  def close_menu(js \\ %JS{}, id) do
    js
    |> JS.set_attribute({"hidden", "hidden"}, to: "##{id}-list")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-button")
  end

  defp toggle_menu(id) do
    JS.toggle_attribute({"hidden", "hidden"}, to: "##{id}-list")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{id}-button")
    |> JS.focus_first(to: "##{id}-list")
  end

  @doc "X, GitHub and ENS as the Socials rows show them, each asking for sign-in."
  def signed_out_socials(assigns) do
    ~H"""
    <ul class="connections__list">
      <.connection
        :for={{label, icon} <- [{"X", :x}, {"GitHub", :github}, {"ENS", :ens}]}
        label={label}
        icon={icon}
      >
        <:actions>
          <Regent.Primitives.button type="button" variant="secondary" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:actions>
      </.connection>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :symbol, :string, required: true
  attr :image, :string, default: nil
  attr :color, :string, default: nil, doc: "the image's colour, which tints the picture's tile"
  attr :pair, :string, required: true, doc: "what the token trades against"
  attr :chain, :atom, required: true, values: [:base, :robinhood]
  attr :sold, :string, required: true, doc: "the share of the supply sold at auction"
  attr :connections, :map, default: %{}, doc: "the creator's connected accounts"
  attr :terms, :list, required: true, doc: "every term, as label and value pairs"

  slot :row, required: true, doc: "a figure, under its label" do
    attr :label, :string, required: true
  end

  @doc """
  The launch at a glance beside the form: its picture, name and pair, its
  chain, the share sold at auction, its figures at the starting price, and
  every term under one fold.
  """
  def summary_card(assigns) do
    assigns =
      assign(assigns,
        name: present(assigns.name, "Your token"),
        symbol: present(String.upcase(assigns.symbol), "TICKER"),
        creator: List.first(MarketCard.connection_list(assigns.connections))
      )

    ~H"""
    <article id={@id} class="create-card rg-panel rg-panel--surface">
      <div class="create-card__top">
        <span class="create-card__tile" style={@color && "--image-color: #{@color}"}>
          <img
            :if={@image not in [nil, ""]}
            src={StoredImage.sized(@image, 160)}
            alt=""
            width="56"
            height="56"
            decoding="async"
          />
          <span :if={@image in [nil, ""]} aria-hidden="true">{String.first(@name)}</span>
        </span>
        <div class="create-card__names">
          <strong>{@name}</strong>
          <span>{@symbol} / {@pair}</span>
          <span :if={@creator}>by {@creator.handle}</span>
        </div>
      </div>
      <span class="create-card__chain">
        <span class={"create-chain create-chain--#{@chain}"} aria-hidden="true"></span>
        {Autolaunch.LaunchChain.label(@chain)}
      </span>
      <div class="create-card__sold">
        <span class="create-card__meter" aria-hidden="true"><i style={"width: #{@sold}"}></i></span>
        <p><span>Auction</span><span>{@sold}</span></p>
      </div>
      <dl class="create-card__rows">
        <div :for={row <- @row}>
          <dt>{row.label}</dt>
          <dd>{render_slot(row)}</dd>
        </div>
      </dl>
      <Regent.Primitives.disclosure
        id={"#{@id}-terms"}
        summary="Every term"
        class="create-card__terms"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <dl class="create-card__rows create-card__rows--terms">
          <div :for={{label, value} <- @terms}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        </dl>
      </Regent.Primitives.disclosure>
    </article>
    """
  end

  defp present(value, placeholder) do
    case String.trim(value || "") do
      "" -> placeholder
      value -> value
    end
  end
end
