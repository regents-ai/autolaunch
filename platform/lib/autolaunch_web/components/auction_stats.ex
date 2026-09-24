defmodule AutolaunchWeb.Components.AuctionStats do
  @moduledoc """
  The thin band of Revstake and Memestake auction counts shown on the home,
  auctions and create pages. Each group loads on its own, so a slow or failed
  Robinhood read leaves the Revstake counts in place.
  """
  use Phoenix.Component

  alias Autolaunch.AuctionStats
  alias Phoenix.LiveView
  require Phoenix.LiveView

  def assign_auction_stats(socket) do
    socket
    |> LiveView.assign_async(:revstake_stats, fn ->
      with {:ok, counts} <- AuctionStats.revstake(), do: {:ok, %{revstake_stats: counts}}
    end)
    |> LiveView.assign_async(:memestake_stats, fn ->
      with {:ok, counts} <- AuctionStats.memestake(), do: {:ok, %{memestake_stats: counts}}
    end)
  end

  attr :revstake, LiveView.AsyncResult, required: true
  attr :memestake, LiveView.AsyncResult, required: true

  def auction_stats(assigns) do
    ~H"""
    <section id="auction-stats" class="auction-stats rg-support-band" aria-label="Auction counts">
      <.group id="auction-stats-revstake" title="Revstake Auctions" stats={@revstake} />
      <.group id="auction-stats-memestake" title="Memestake Auctions" stats={@memestake} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :stats, LiveView.AsyncResult, required: true

  defp group(assigns) do
    ~H"""
    <div id={@id} class="auction-stats__group" aria-busy={to_string(@stats.loading != nil)}>
      <p class="auction-stats__title">{@title}</p>
      <p :if={@stats.failed} class="auction-stats__note">Counts unavailable right now</p>
      <dl :if={!@stats.failed} class="auction-stats__counts">
        <div>
          <dt>Live:</dt>
          <dd>{count(@stats, :live)}</dd>
        </div>
        <div>
          <dt>Launched:</dt>
          <dd>{count(@stats, :graduated)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp count(%{ok?: true, result: counts}, key), do: Map.fetch!(counts, key)
  defp count(_loading, _key), do: "…"
end
