defmodule Autolaunch.NearFunding.Refresh do
  @moduledoc """
  The `:refresh` action of `Autolaunch.NearFunding`: reads a funding's swap
  status from the 1Click service once, outside any database transaction, then
  stores it (`:store_status`, which broadcasts a change of state). The funding
  is given as itself or by its id, read as the caller, so only its own account
  or the system refreshes it.
  """

  alias Autolaunch.NearFunding
  alias Autolaunch.NearFunding.Intents

  @spec run(Ash.Resource.record() | String.t(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def run(funding, opts) do
    with {:ok, funding} <- funding(funding, opts),
         {:ok, status} <- status(funding) do
      funding
      |> Ash.Changeset.for_update(:store_status, status, opts)
      |> Ash.update()
    end
  end

  defp funding(%NearFunding{} = funding, _opts), do: {:ok, funding}
  defp funding(id, opts), do: Autolaunch.Funding.near_funding(id, opts)

  defp status(funding) do
    case Intents.status(funding.deposit_address) do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, Ash.Error.Unknown.UnknownError.exception(error: reason)}
    end
  end
end
