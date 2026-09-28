defmodule Autolaunch.Popular do
  @moduledoc """
  The search's recently popular list: auctions by the dollars bid on them and
  tokens by the dollars traded in them, both over the last day, ranked
  together. Anything with no bids or trades in the day is not in it, and an
  auction or token whose currency has no dollar price is left out rather than
  guessed.
  """

  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @type entry :: %{
          kind: :auction | :token,
          record: struct(),
          auction: struct(),
          usd: Decimal.t()
        }

  @doc """
  Everything bid on or traded in the last day, most dollars first. `rate`
  gives the dollar price of one unit of an auction's currency, nil while none
  is known; a token trades in its auction's currency.
  """
  @spec read((struct() -> Decimal.t() | nil)) :: {:ok, [entry()]} | {:error, term()}
  def read(rate) do
    with {:ok, auctions} <- Autolaunch.list_popular_auctions(actor: nil),
         {:ok, tokens} <- Autolaunch.list_popular_tokens(actor: nil) do
      entries =
        Enum.map(auctions, &entry(:auction, &1, &1, &1.bid_amount_today, rate)) ++
          Enum.map(tokens, &entry(:token, &1, &1.auction, &1.traded_today, rate))

      {:ok,
       entries
       |> Enum.reject(&is_nil(&1.usd))
       |> Enum.sort_by(& &1.usd, {:desc, Decimal})}
    end
  end

  @doc """
  The first `limit` entries on the chosen chain (`"base"` or `"robinhood"`),
  of the chosen type (`"revstake"` or `"memestake"`) and showing the chosen
  kind (`"auctions"` or `"tokens"`); `"all"` takes any.
  """
  @spec pick([entry()], %{chain: String.t(), kind: String.t(), show: String.t()}, pos_integer()) ::
          [entry()]
  def pick(entries, %{chain: chain, kind: kind, show: show}, limit) do
    entries
    |> Enum.filter(&(chain?(&1.auction, chain) and kind?(&1.auction, kind) and show?(&1, show)))
    |> Enum.take(limit)
  end

  defp entry(kind, record, auction, amount, rate),
    do: %{kind: kind, record: record, auction: auction, usd: dollars(amount, rate.(auction))}

  defp dollars(amount, %Decimal{} = rate), do: Decimal.mult(amount, rate)
  defp dollars(_amount, _unknown), do: nil

  defp chain?(_auction, "all"), do: true
  defp chain?(auction, "base"), do: auction.chain_id == Lab.chain_id()
  defp chain?(auction, "robinhood"), do: auction.chain_id == RobinhoodLab.chain_id()

  defp kind?(_auction, "all"), do: true
  defp kind?(auction, "revstake"), do: auction.kind == :agent
  defp kind?(auction, "memestake"), do: auction.kind == :stocks

  defp show?(_entry, "all"), do: true
  defp show?(entry, "auctions"), do: entry.kind == :auction
  defp show?(entry, "tokens"), do: entry.kind == :token
end
