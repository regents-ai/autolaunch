defmodule Autolaunch.AuctionStats do
  @moduledoc """
  Live and graduated auction counts for the two launch types, over the
  auctions the public lists carry. Revstake auctions are the Base agent
  auctions. Memestock auctions are the stock auctions on both chains. Live
  means open for bidding, the same as the market's live filter.
  """

  alias Autolaunch.Auction
  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @type counts :: %{live: non_neg_integer(), graduated: non_neg_integer()}

  @spec revstake() :: {:ok, counts()} | {:error, term()}
  def revstake, do: counts(kind: :agent)

  @spec memestock() :: {:ok, counts()} | {:error, term()}
  def memestock, do: counts(kind: :stocks)

  @doc """
  The same counts for each launch type on each chain it runs on, as the public
  API gives them: Revstake on Base, Memestock on Base and on Robinhood.
  """
  @spec by_chain() ::
          {:ok, %{revstake: %{base: counts()}, memestock: %{base: counts(), robinhood: counts()}}}
          | {:error, term()}
  def by_chain do
    with {:ok, revstake} <- counts(kind: :agent, chain_id: Lab.chain_id()),
         {:ok, base} <- counts(kind: :stocks, chain_id: Lab.chain_id()),
         {:ok, robinhood} <- counts(kind: :stocks, chain_id: RobinhoodLab.chain_id()) do
      {:ok, %{revstake: %{base: revstake}, memestock: %{base: base, robinhood: robinhood}}}
    end
  end

  defp counts(filter) do
    with {:ok, live} <- count([{:state, :active} | filter]),
         {:ok, graduated} <- count([{:state, :graduated} | filter]) do
      {:ok, %{live: live, graduated: graduated}}
    end
  end

  defp count(filter) do
    Auction
    |> Ash.Query.for_read(:listed, %{}, actor: nil)
    |> Ash.Query.do_filter(filter)
    |> Ash.count()
  end
end
