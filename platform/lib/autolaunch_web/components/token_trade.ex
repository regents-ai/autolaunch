defmodule AutolaunchWeb.Components.TokenTrade do
  @moduledoc """
  The trade widget of a token page, on Base and Robinhood alike: a sliding
  selector of Swap, Stake and, for a wallet that has a stake, Unstake, over
  one view at a time. Every view shares one cell, so choosing another never
  changes the widget's height. The page owns the choice (`tab`) and the views;
  `tabs/2` and `pick/2` keep both pages choosing the same way.
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
      <div
        id={"#{@id}-panel"}
        class="token-trade__panes"
        role="tabpanel"
        aria-labelledby={"#{@id}-tab-#{@tab}"}
      >
        <div
          :for={pane <- @pane}
          class="token-trade__pane"
          data-pane={pane.tab}
          inert={!showing?(pane.tab, @tab)}
        >
          {render_slot(pane)}
        </div>
      </div>
    </section>
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
