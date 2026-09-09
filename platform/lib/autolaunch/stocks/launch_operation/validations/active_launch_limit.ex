defmodule Autolaunch.Stocks.LaunchOperation.Validations.ActiveLaunchLimit do
  @moduledoc """
  One Stocks auction in progress per account, a site rule rather than a
  contract rule. A new review is refused while this account has a Stocks
  `Auction` that is created or active; graduated and failed auctions free the
  slot. The Agent limit (`Autolaunch.LaunchOperation.Validations.AuctionLimit`)
  is separate and untouched.
  """
  use Ash.Resource.Validation

  @message "You already have a stock launch in progress. One at a time for now."

  def message, do: @message

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :human_account_id) do
      id when is_integer(id) -> check_limit(id)
      _ -> :ok
    end
  end

  defp check_limit(id) do
    case Autolaunch.active_stocks_auctions_by(id) do
      0 ->
        :ok

      n ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :human_account_id,
           message: @message,
           value: n,
           vars: [code: :active_stocks_launch_exists]
         )}
    end
  end
end
