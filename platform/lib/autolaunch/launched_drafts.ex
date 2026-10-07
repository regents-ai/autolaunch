defmodule Autolaunch.LaunchedDrafts do
  @moduledoc """
  Starts an account's draft over once the launch it described is listed, so
  the create page opens on a blank form. It runs where the listing is written
  (`Autolaunch.LaunchReviews` on Base, `Autolaunch.Robinhood.MarketFeed` on
  Robinhood), inside the same transaction.

  Only a draft that still names the listed launch is cleared: a second
  listing of the same launch, or a draft its creator has already rewritten,
  is left as it is.
  """

  alias Autolaunch.Actors.Human

  @type kind :: :revstake | :memestake

  @spec clear(kind(), integer(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear(kind, account_id, name, symbol) do
    actor = %Human{human_account_id: account_id}

    case read(kind, actor) do
      {:ok, %{name: ^name, symbol: ^symbol} = draft} -> cleared(kind, draft, actor)
      {:ok, _other_or_none} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp read(:revstake, actor), do: Autolaunch.get_my_account_launch_draft(actor: actor)
  defp read(:memestake, actor), do: Autolaunch.get_my_stocks_launch_draft(actor: actor)

  defp cleared(kind, draft, actor) do
    case clear_draft(kind, draft, actor) do
      {:ok, _draft} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp clear_draft(:revstake, draft, actor),
    do: Autolaunch.clear_launch_draft(draft, actor: actor)

  defp clear_draft(:memestake, draft, actor),
    do: Autolaunch.clear_stocks_launch_draft(draft, actor: actor)
end
