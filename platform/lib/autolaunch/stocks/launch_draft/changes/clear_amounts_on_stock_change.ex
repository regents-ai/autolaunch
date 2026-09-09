defmodule Autolaunch.Stocks.LaunchDraft.Changes.ClearAmountsOnStockChange do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Chain.Address

  # The minimum raise and floor price are denominated in the chosen STOCK, so a
  # different currency makes the amounts entered under the old one meaningless:
  # each is cleared unless this same save is entering it afresh.
  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :stock_address) and
         not same_stock?(changeset.data.stock_address, next_stock(changeset)) do
      Enum.reduce([:minimum_raise, :floor_price], changeset, &clear_stale/2)
    else
      changeset
    end
  end

  defp clear_stale(field, changeset) do
    if Ash.Changeset.changing_attribute?(changeset, field),
      do: changeset,
      else: Ash.Changeset.force_change_attribute(changeset, field, nil)
  end

  defp next_stock(changeset), do: Ash.Changeset.get_attribute(changeset, :stock_address)

  defp same_stock?(nil, nil), do: true
  defp same_stock?(current, next), do: Address.equal?(current, next)
end
