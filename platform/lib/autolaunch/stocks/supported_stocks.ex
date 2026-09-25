defmodule Autolaunch.Stocks.SupportedStocks do
  @moduledoc """
  Records every stock the chains' lists offer as an `Autolaunch.Stocks.Stock`
  row when the site starts, so search knows each stock's name.
  """

  alias Autolaunch.Stocks.{Assets, Stock}

  @doc false
  def child_spec(_arg), do: Task.child_spec(&record/0)

  @spec record() :: :ok
  def record do
    rows =
      for chain <- [:base, :robinhood], asset <- Assets.all(chain) do
        Map.take(asset, [:chain_id, :address, :symbol, :name])
      end

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(rows, Stock, :record_supported,
        actor: %Autolaunch.Actors.System{},
        return_errors?: true,
        stop_on_error?: true
      )

    :ok
  end
end
