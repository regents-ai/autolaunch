defmodule Autolaunch.LaunchedDrafts do
  @moduledoc """
  Starts an account's draft over once the launch it described is made, so
  the create page opens on a blank form. It runs where the listing is written
  (`Autolaunch.LaunchReviews` on Base, `Autolaunch.Robinhood.MarketFeed` on
  Robinhood), inside the same transaction, and as soon as the creator's own
  page sees its launch confirmed (`AutolaunchWeb.LaunchSteps.launched/4`), as
  the system: clearing a launched draft is the site's step, not the account's.

  Only a draft that still names the listed launch is cleared: a second
  listing of the same launch, or a draft its creator has already rewritten,
  is left as it is.
  """

  alias Autolaunch.Actors.System

  @system %System{}

  @type kind :: :revstake | :memestake

  @spec clear(kind(), integer(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear(kind, account_id, name, symbol) do
    case naming(kind, account_id, name, symbol) do
      {:ok, nil} -> :ok
      {:ok, draft} -> cleared(kind, draft)
      {:error, error} -> {:error, error}
    end
  end

  defp naming(:revstake, account_id, name, symbol),
    do: Autolaunch.get_launch_draft_naming_listed_launch(account_id, name, symbol, actor: @system)

  defp naming(:memestake, account_id, name, symbol),
    do:
      Autolaunch.get_stocks_launch_draft_naming_listed_launch(account_id, name, symbol,
        actor: @system
      )

  defp cleared(kind, draft) do
    case clear_draft(kind, draft) do
      {:ok, _draft} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp clear_draft(:revstake, draft), do: Autolaunch.clear_launch_draft(draft, actor: @system)

  defp clear_draft(:memestake, draft),
    do: Autolaunch.clear_stocks_launch_draft(draft, actor: @system)
end
