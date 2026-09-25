defmodule Autolaunch.Search do
  @moduledoc """
  The gallery search, shared by auctions and tokens.

  Each resource ranks itself against a search with its `search_rank`
  calculation: how closely the words match its name, ticker, stock, creator
  accounts or description, from 0 to 1, with typos still scoring close to a
  match (pg_trgm's `word_similarity`). A search that looks like part of a
  wallet or contract address also matches that address outright. Results keep
  the ones that match well enough, best first.
  """

  require Ash.Query

  # Close enough to count: one wrong letter in a five-letter word still passes.
  @match 0.45
  @limit 80

  @doc "The one form a search takes: single spaces, no spaces at either end, at most eighty characters."
  @spec normalize(term()) :: String.t()
  def normalize(value) when is_binary(value) do
    value
    |> String.split()
    |> Enum.join(" ")
    |> String.graphemes()
    |> Enum.take(@limit)
    |> Enum.join()
  end

  def normalize(_value), do: ""

  @doc "Keeps the records that match `search` and sorts them best first, then by `order`."
  @spec rank(Ash.Query.t(), String.t(), keyword()) :: Ash.Query.t()
  def rank(query, "", order), do: Ash.Query.sort(query, order)

  def rank(query, search, order) do
    arguments = %{term: String.downcase(search), address: address_part(search)}

    query
    |> Ash.Query.filter(
      search_rank(term: ^arguments.term, address: ^arguments.address) >= ^@match
    )
    |> Ash.Query.sort([{:search_rank, {arguments, :desc}} | order])
  end

  defp address_part(search) do
    search = String.downcase(search)
    if Regex.match?(~r/\A(0x)?[0-9a-f]{6,40}\z/, search), do: search
  end
end
