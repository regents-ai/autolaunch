defmodule Autolaunch.Points.AccountActivated do
  @moduledoc """
  Regent Points' check of a new account (`account.activated`): it reads the
  shared account row and answers with what Points records. The account was
  activated when it was created.

  The account is one Regents account on every site, so its source is the
  template's on every site (`source_app` "regents"): it earns once, whichever
  site saw it first.

  The shared account table keeps that time to the second, rounded, so for up
  to half a second after the sign-in it can be ahead of the clock; the check
  then runs again later rather than turning the award down.

  `existing/2` lists the accounts made before `at`, the start run's own time,
  for `RegentPoints.StartAwards`, which leaves out every account any site
  already recorded. The table holds every Regent site's accounts, so the run
  can record one made on another site that no site has recorded yet; it earns
  once either way. One made before the Points start earns at the start, a later
  one at its own time.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System

  def verify(%{"source_event_key" => id}) do
    case Accounts.points_account(String.to_integer(id), actor: %System{}) do
      {:ok, account} ->
        if DateTime.after?(account.created_at, DateTime.utc_now()),
          do: {:retry, :account_created_ahead_of_clock},
          else: {:ok, facts(account)}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  def existing("account.activated", at) do
    for account <- Accounts.accounts_created_before!(at, actor: %System{}) do
      {account.id,
       %{source_app: "regents", source_kind: "account", source_event_key: to_string(account.id)}}
    end
  end

  defp facts(account) do
    id = to_string(account.id)

    %{
      # The same source as Autolaunch.Points.Award: one Regents account on every site.
      source_app: "regents",
      source_kind: "account",
      source_event_key: id,
      account_id: account.id,
      actor_kind: "human",
      actor_id: id,
      source_action_at: account.created_at,
      qualified_at: account.created_at,
      evidence_ref: "account:" <> id,
      evidence: %{}
    }
  end
end
