defmodule Autolaunch.Stocks.LaunchDraft.Changes.CarryStock do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Stocks.Assets

  # The stock list is per chain: a new chain keeps the paired company when the
  # old chain still offers the stock and the new chain offers one under the
  # same ticker, and starts without a stock otherwise.
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :stock_address, carried(changeset))
  end

  defp carried(%{data: %{chain: from, stock_address: address}}) when is_binary(address) do
    case Assets.counterpart(from, address) do
      {:ok, %{address: carried}} -> carried
      :error -> nil
    end
  end

  defp carried(_changeset), do: nil
end
