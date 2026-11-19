defmodule Autolaunch.Points.ConnectedX do
  @moduledoc """
  Regent Points' check of an X account (`social.x`): on this site a person's X
  is the profile connection the Account page's X button makes
  (`Autolaunch.Accounts.XConnection`, role `:profile`). It reads that
  connection and answers with what Points records. A company connection never
  earns, and an X account Privy lists earns on the site that linked it, never
  here.

  The proof is the X account's user id, the same id Privy keeps as the
  `subject` of a linked X account, so one X account earns once, whichever
  account connects it and on whichever Regent site. When more than one account
  has connected it, the one that connected it first, while it stays connected,
  is the one that earns; a connection removed before the check earns nothing.

  `existing/2` lists the profile connections made before the Points start and
  still connected, one for each X account, for `RegentPoints.StartAwards`.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System

  def verify(%{"source_event_key" => "x:" <> x_user_id = key}) do
    case Accounts.get_connected_x_profile(x_user_id, actor: %System{}) do
      {:ok, %{} = connection} -> {:ok, facts(connection, key)}
      {:ok, nil} -> {:error, :x_connection_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  def existing("social.x", starts_at) do
    starts_at
    |> Accounts.x_profiles_connected_before!(actor: %System{})
    |> Enum.uniq_by(& &1.x_user_id)
    |> Enum.map(fn connection ->
      {connection.human_account_id,
       %{
         source_app: Autolaunch.Points.source_app(),
         source_kind: "x_connection",
         source_event_key: "x:" <> connection.x_user_id
       }}
    end)
  end

  defp facts(connection, key) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: "x_connection",
      source_event_key: key,
      account_id: connection.human_account_id,
      actor_kind: "human",
      actor_id: to_string(connection.human_account_id),
      # When the X button last connected this X account.
      source_action_at: connection.verified_at,
      qualified_at: connection.verified_at,
      evidence_ref: "x_connection:" <> connection.id,
      evidence: %{"subject_key" => key}
    }
  end
end
