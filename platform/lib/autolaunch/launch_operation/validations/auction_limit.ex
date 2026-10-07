defmodule Autolaunch.LaunchOperation.Validations.AuctionLimit do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :human_account_id) do
      id when is_integer(id) -> check_limit(id)
      _ -> :ok
    end
  end

  defp check_limit(id) do
    n = Autolaunch.auctions_prepared_by(id)

    if n >= Autolaunch.Limits.auctions_per_account() do
      {:error,
       Ash.Error.Invalid.Unavailable.exception(
         resource: Autolaunch.LaunchOperation,
         reason: :auction_limit_reached
       )}
    else
      :ok
    end
  end
end
