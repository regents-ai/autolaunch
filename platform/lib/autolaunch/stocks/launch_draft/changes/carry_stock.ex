defmodule Autolaunch.Stocks.LaunchDraft.Changes.CarryStock do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Stocks.Assets
  alias RegentChain.Address

  # The stock list is per chain: a new chain keeps the paired company when the
  # old chain still offers the stock and the catalog pairs it with one the new
  # chain offers, and starts without a stock otherwise.
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :stock_address, carried(changeset))
  end

  defp carried(%{data: %{chain: from, stock_address: address}} = changeset)
       when is_binary(address) do
    to = Ash.Changeset.get_attribute(changeset, :chain)

    with %{address: listed} <- Enum.find(Assets.all(from), &Address.equal?(&1.address, address)),
         {:ok, counterpart} <- Assets.counterpart(from, listed),
         %{address: carried} <-
           Enum.find(Assets.all(to), &Address.equal?(&1.address, counterpart)) do
      carried
    else
      _none -> nil
    end
  end

  defp carried(_changeset), do: nil
end
