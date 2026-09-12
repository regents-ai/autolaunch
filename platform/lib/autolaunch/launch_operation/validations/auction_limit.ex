defmodule Autolaunch.LaunchOperation.Validations.AuctionLimit do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case {Ash.Changeset.get_argument(changeset, :human_account_id),
          Ash.Changeset.get_attribute(changeset, :chain)} do
      {id, chain} when is_integer(id) and is_atom(chain) -> check_limit(id, chain)
      _ -> :ok
    end
  end

  defp check_limit(id, chain) do
    n = Autolaunch.auctions_prepared_by(id, chain)

    if n >= Autolaunch.Limits.auctions_per_account() do
      {:error,
       Ash.Error.Changes.InvalidArgument.exception(
         field: :human_account_id,
         message: "You already have an auction on this chain. One auction per chain for now.",
         value: n,
         vars: [code: :auction_limit_reached]
       )}
    else
      :ok
    end
  end
end
