defmodule Autolaunch.AuctionStats do
  @moduledoc """
  Live and graduated auction counts for the two launch types. Revstake
  auctions are the stored Base agent auctions. Memestake auctions are the
  stored Base stock auctions plus the Robinhood auctions read from their
  chain. Live means open for bidding, the same as the market's live filter.
  """

  alias Autolaunch.Auction
  alias Autolaunch.Robinhood.Auctions, as: RobinhoodAuctions

  require Ash.Query

  @type counts :: %{live: non_neg_integer(), graduated: non_neg_integer()}

  @spec revstake() :: {:ok, counts()} | {:error, term()}
  def revstake, do: stored(:agent)

  @spec memestake() :: {:ok, counts()} | {:error, term()}
  def memestake do
    with {:ok, base} <- stored(:stocks),
         {:ok, robinhood} <- RobinhoodAuctions.list() do
      {:ok,
       %{
         live: base.live + Enum.count(robinhood, &(&1.state == :active)),
         graduated: base.graduated + Enum.count(robinhood, &(&1.state == :graduated))
       }}
    end
  end

  defp stored(kind) do
    with {:ok, live} <- count(kind, :active),
         {:ok, graduated} <- count(kind, :graduated) do
      {:ok, %{live: live, graduated: graduated}}
    end
  end

  defp count(kind, state) do
    Auction
    |> Ash.Query.for_read(:read, %{}, actor: nil)
    |> Ash.Query.filter(kind == ^kind and state == ^state)
    |> Ash.count()
  end
end
