defmodule AutolaunchWeb.Components.TokenTrade do
  @moduledoc """
  The trade widget of a token page, on Base and Robinhood alike: a sliding
  selector of Swap, Stake and, for a wallet that has a stake, Unstake, over
  one view at a time. Each view takes its own height, and the widget eases
  between them (`TradeViews`). The page owns the choice (`tab`) and the views;
  `tabs/2` and `pick/2` keep both pages choosing the same way. A small button
  at the end of the selector asks the page to read the wallet's figures again
  (`refresh_balances`).
  """
  use Phoenix.Component

  @doc """
  The views the widget offers: Swap where the token can be swapped here,
  Stake always, and Unstake only for a wallet the chain says has a stake.
  """
  def tabs(swap?, staked?) do
    Enum.filter([:swap, :stake, :unstake], fn
      :swap -> swap?
      :stake -> true
      :unstake -> staked?
    end)
  end

  @doc "The view named by `name` when the widget offers it, else the first one it offers."
  def pick(name, tabs), do: Enum.find(tabs, hd(tabs), &(Atom.to_string(&1) == name))

  attr :id, :string, required: true
  attr :tab, :atom, required: true, doc: "the view showing"
  attr :swap, :boolean, required: true, doc: "whether the token can be swapped here"
  attr :staked, :boolean, required: true, doc: "whether the wallet has a stake"

  slot :pane, required: true, doc: "one view; the Stake view also shows Unstake" do
    attr :tab, :atom, required: true
  end

  def trade_widget(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-trade"
      aria-label="Trade"
      phx-hook="MotionTabs"
      data-active={@tab}
      data-variant={AutolaunchWeb.Motion.standard("tabs")}
    >
      <%!-- Unstake stays in the page while it is not offered, so the selector's
           motion knows every tab from the start and its ink is never redrawn. --%>
      <div class="token-trade__tabs" role="tablist" aria-label="Trade">
        <span
          id={"#{@id}-ink"}
          class="token-trade__ink"
          data-ink
          aria-hidden="true"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style"])}
        ></span>
        <button
          :for={tab <- tabs(@swap, true)}
          type="button"
          role="tab"
          id={"#{@id}-tab-#{tab}"}
          data-tab={tab}
          hidden={tab not in tabs(@swap, @staked)}
          aria-selected={to_string(tab == @tab)}
          aria-controls={"#{@id}-panel"}
          phx-click="trade"
          phx-value-tab={tab}
        >
          {label(tab)}
        </button>
      </div>
      <Regent.Primitives.button
        type="button"
        variant="quiet"
        class="token-trade__refresh"
        phx-click={
          Phoenix.LiveView.JS.push("refresh_balances")
          |> Phoenix.LiveView.JS.transition("token-trade__refresh--turn", time: 600)
        }
        aria-label="Refresh balances"
        title="Refresh balances"
      >
        <svg viewBox="0 0 24 24" width="20" height="20" fill="none" aria-hidden="true">
          <path
            d="M20 12a8 8 0 1 1-2.34-5.66M20 4v4h-4"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </Regent.Primitives.button>
      <div
        id={"#{@id}-panel"}
        class="token-trade__panes"
        role="tabpanel"
        aria-labelledby={"#{@id}-tab-#{@tab}"}
      >
        <div
          id={"#{@id}-views"}
          class="token-trade__views"
          phx-hook="TradeViews"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style", "data-resizing"])}
          data-active={@tab}
        >
          <div
            :for={pane <- @pane}
            class="token-trade__pane"
            data-pane={pane.tab}
            hidden={!showing?(pane.tab, @tab)}
          >
            {render_slot(pane)}
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc """
  The ground the trade widget and Claim Rewards stand on: the soft light behind
  their buttons (`SiteLight`) and the press their buttons make (`SiteButtons`),
  as the template's study of the site's buttons has them.
  """
  def buttons_stage(assigns) do
    ~H"""
    <div
      id={@id}
      class={["site-light-stage", @class]}
      phx-hook="SiteButtons"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("data-input")}
    >
      <div
        id={@id <> "-light"}
        class="site-light"
        phx-hook="SiteLight"
        phx-update="ignore"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("data-light-ready")}
        aria-hidden="true"
      >
        <canvas data-light-canvas></canvas>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :pool, :map, required: true, doc: "the page's pool read, while it is not ready"

  @doc """
  Where the Stake view would be while the pool is being read, before the
  token has a pool, or when the chain could not be read.
  """
  def pool_status(assigns) do
    ~H"""
    <p :if={@pool.loading} class="token-trade__status" role="status">Reading the pool…</p>
    <p :if={@pool.failed == {:error, :not_graduated}} class="token-trade__status">
      Staking opens once this token is in its pool.
    </p>
    <div :if={unreadable?(@pool)} class="token-trade__status" role="alert">
      <p>The pool could not be read just now.</p>
      <Regent.Primitives.button phx-click="reload_pool" variant="secondary">
        Read again
      </Regent.Primitives.button>
    </div>
    """
  end

  defp label(:swap), do: "Swap"
  defp label(:stake), do: "Stake"
  defp label(:unstake), do: "Unstake"

  defp showing?(:stake, tab), do: tab in [:stake, :unstake]
  defp showing?(pane, tab), do: pane == tab

  defp unreadable?(%{failed: nil}), do: false
  defp unreadable?(%{failed: {:error, :not_graduated}}), do: false
  defp unreadable?(_failed), do: true
end
