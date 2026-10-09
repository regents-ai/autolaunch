defmodule Autolaunch.LaunchedDrafts do
  @moduledoc """
  Starts an account's draft over once the launch it described is made, so
  the create page opens on a blank form. It runs where the listing is written
  (`Autolaunch.LaunchReviews` on Base, `Autolaunch.Robinhood.MarketFeed` on
  Robinhood), inside the same transaction, and as soon as the creator's own
  page sees its launch confirmed (`AutolaunchWeb.LaunchSteps.launched/4`), as
  the system: clearing a launched draft is the site's step, not the account's.

  Only a draft that still names the listed launch is cleared, matched by the
  same statement that blanks it: a second listing of the same launch, or a
  draft its creator has already rewritten (even from another tab a moment
  before), is left as it is.
  """

  alias Autolaunch.Actors.System

  @system %System{}

  @type kind :: :revstake | :memestake

  @spec clear(kind(), integer(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear(kind, account_id, name, symbol) do
    case cleared(kind, account_id, name, symbol) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
    end
  end

  defp cleared(:revstake, account_id, name, symbol) do
    account_id
    |> Autolaunch.query_to_launch_draft_naming_listed_launch(name, symbol, actor: @system)
    |> Autolaunch.clear_launch_draft(actor: @system)
  end

  defp cleared(:memestake, account_id, name, symbol) do
    account_id
    |> Autolaunch.query_to_stocks_launch_draft_naming_listed_launch(name, symbol, actor: @system)
    |> Autolaunch.clear_stocks_launch_draft(actor: @system)
  end
end
