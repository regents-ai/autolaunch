defmodule Autolaunch.AuctionFire do
  @moduledoc """
  A shared flame on an auction page: one viewer clicks, and every page open on
  that auction shows a flame at the same spot.

  Nothing is stored and nobody is named. A click carries only where it landed
  as a fraction of the viewer's page, so pages of any size agree on the spot,
  and one page may light at most one flame every two seconds.
  """

  @cooldown_ms 2_000

  @spec cooldown_ms() :: pos_integer()
  def cooldown_ms, do: @cooldown_ms

  @spec topic(String.t()) :: String.t()
  def topic(auction_id) when is_binary(auction_id), do: "auction-fire:" <> auction_id

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(auction_id), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(auction_id))

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(auction_id),
    do: Phoenix.PubSub.unsubscribe(Autolaunch.PubSub, topic(auction_id))

  @doc """
  Lights one flame at a point inside the page, or refuses anything else. The
  message names its auction so a page that has moved on can tell it apart.
  """
  @spec light(String.t(), term()) :: :ok | :error
  def light(auction_id, %{"x" => x, "y" => y})
      when is_number(x) and is_number(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1 do
    Phoenix.PubSub.broadcast(
      Autolaunch.PubSub,
      topic(auction_id),
      {:auction_fire, auction_id, %{x: x / 1, y: y / 1}}
    )
  end

  def light(_auction_id, _point), do: :error
end
