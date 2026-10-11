defmodule Autolaunch.Stocks.LaunchDraft.Changes.CarryStock do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Stocks.{Assets, PriceFeeds}
  alias RegentChain.Address

  # The stock list is per chain: a new chain keeps the paired company when it
  # offers that company's stock too, and starts without a paired stock when not.
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :stock_address, carried(changeset))
  end

  defp carried(%{data: %{chain: from, stock_address: address}} = changeset)
       when is_binary(address) do
    to = Ash.Changeset.get_attribute(changeset, :chain)

    with %{symbol: symbol} <- Enum.find(Assets.all(from), &Address.equal?(&1.address, address)),
         %{address: carried} <- Enum.find(Assets.all(to), &same_company?(&1, symbol)) do
      carried
    end
  end

  defp carried(_changeset), do: nil

  defp same_company?(stock, symbol),
    do: PriceFeeds.ticker(stock.symbol) == PriceFeeds.ticker(symbol)
end
