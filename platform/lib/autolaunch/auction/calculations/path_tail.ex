defmodule Autolaunch.Auction.Calculations.PathTail do
  @moduledoc """
  The end of an auction's contract address that its page addresses carry
  after its ticker, as in `/auctions/BITE/80be8`: the last five characters in
  lowercase, or as many more as it takes to tell the auction apart from every
  other listed auction with the same ticker, ignoring case, on either chain.
  """
  use Ash.Resource.Calculation

  @shortest 5
  @longest 40

  @impl true
  def load(_query, _opts, _context), do: [:token_symbol, :auction_address]

  @impl true
  def calculate(auctions, _opts, _context) do
    symbols = auctions |> Enum.map(&symbol_key/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with {:ok, peers} <- Autolaunch.list_path_peers(symbols, actor: nil) do
      {:ok, Enum.map(auctions, &tail(&1, peers))}
    end
  end

  defp tail(auction, peers) do
    address = String.downcase(auction.auction_address)
    symbol = symbol_key(auction)

    shared =
      peers
      |> Enum.filter(&(&1.id != auction.id and symbol_key(&1) == symbol))
      |> Enum.map(&shared_end(address, String.downcase(&1.auction_address)))
      |> Enum.max(fn -> 0 end)

    String.slice(address, -min(max(shared + 1, @shortest), @longest)..-1//1)
  end

  defp symbol_key(%{token_symbol: symbol}) when is_binary(symbol), do: String.downcase(symbol)
  defp symbol_key(_auction), do: nil

  # How many characters two addresses share at their end.
  defp shared_end(left, right) do
    left
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.zip(right |> String.reverse() |> String.to_charlist())
    |> Enum.take_while(fn {a, b} -> a == b end)
    |> length()
  end
end
