defmodule Autolaunch.Stocks.LaunchDraft.Changes.CarryStock do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Stocks.Assets
  alias RegentChain.Address

  # The stock list is per chain: a new chain keeps the paired company when the
  # catalog pairs its stock with one the new chain offers, and starts without a
  # paired stock otherwise.
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :stock_address, carried(changeset))
  end

  defp carried(%{data: %{chain: from, stock_address: address}} = changeset)
       when is_binary(address) do
    to = Ash.Changeset.get_attribute(changeset, :chain)

    with {:ok, counterpart} <- Assets.counterpart(from, address),
         %{address: carried} <-
           Enum.find(Assets.all(to), &Address.equal?(&1.address, counterpart)) do
      carried
    else
      _none -> nil
    end
  end

  defp carried(_changeset), do: nil
end
