defmodule Autolaunch.Stocks.LaunchDraft.Changes.ClearStockAmountsOnStockChange do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Chain.Address

  # The required raise and the floor price are denominated in the chosen STOCK,
  # so a different currency makes the amounts entered under the old one
  # meaningless: each is cleared unless this same save is entering it afresh.
  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :stock_address) and
         not same_stock?(changeset.data.stock_address, next_stock(changeset)) do
      changeset |> clear_stale(:required_raise) |> clear_stale(:floor_price)
    else
      changeset
    end
  end

  defp clear_stale(changeset, field) do
    if Ash.Changeset.changing_attribute?(changeset, field),
      do: changeset,
      else: Ash.Changeset.force_change_attribute(changeset, field, nil)
  end

  defp next_stock(changeset), do: Ash.Changeset.get_attribute(changeset, :stock_address)

  defp same_stock?(nil, nil), do: true
  defp same_stock?(current, next), do: Address.equal?(current, next)
end
