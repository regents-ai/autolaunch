defmodule Autolaunch.AuctionStats do
  @moduledoc """
  Live and graduated auction counts for the two launch types, over the
  auctions the public lists carry. Revstake auctions are the Base agent
  auctions. Memestake auctions are the stock auctions on both chains. Live
  means open for bidding, the same as the market's live filter.
  """

  alias Autolaunch.Auction

  require Ash.Query

  @type counts :: %{live: non_neg_integer(), graduated: non_neg_integer()}

  @spec revstake() :: {:ok, counts()} | {:error, term()}
  def revstake, do: counts(:agent)

  @spec memestake() :: {:ok, counts()} | {:error, term()}
  def memestake, do: counts(:stocks)

  defp counts(kind) do
    with {:ok, live} <- count(kind, :active),
         {:ok, graduated} <- count(kind, :graduated) do
      {:ok, %{live: live, graduated: graduated}}
    end
  end

  defp count(kind, state) do
    Auction
    |> Ash.Query.for_read(:listed, %{}, actor: nil)
    |> Ash.Query.filter(kind == ^kind and state == ^state)
    |> Ash.count()
  end
end
