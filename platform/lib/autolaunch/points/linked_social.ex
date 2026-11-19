defmodule Autolaunch.Points.LinkedSocial do
  @moduledoc """
  Regent Points' check of a linked GitHub or Farcaster account
  (`social.github`, `social.farcaster`): it reads the saved link and answers
  with what Points records. The provider and subject are the proof, so one
  social account earns once, whichever account links it and on whichever
  Regent site; a link removed before the check earns nothing. The check answers
  for the account that linked it first and still holds it
  (`Autolaunch.Accounts.LinkedIdentity` `:first_link`), so a later link by
  another account moves nothing earned or waiting; a GitHub or Farcaster
  account is linked to one account at a time, so that is the account holding it.

  An X account earns from the X connection the Account page makes
  (`Autolaunch.Points.ConnectedX`), never from a link Privy lists, which
  several accounts may hold at once.

  `existing/2` lists this site's links to the rule's provider made before `at`,
  the start run's own time, and still there, one for each social account: its
  first, for `RegentPoints.StartAwards`. One linked before the Points start
  earns at the start; a later one, such as one linked while the rule was off,
  at its own time.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System

  def verify(%{"source_event_key" => key}) do
    [provider, subject] = String.split(key, ":", parts: 2)

    case Accounts.get_first_link(provider, subject, actor: %System{}) do
      {:ok, %{} = identity} -> {:ok, facts(identity, key)}
      {:ok, nil} -> {:error, :link_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  def existing("social." <> provider, at) do
    links = Accounts.linked_identities_before!(provider, at, actor: %System{})

    # Of the accounts that hold one social account, only the first to link it.
    for identity <- Enum.uniq_by(links, & &1.subject) do
      {identity.human_account_id,
       %{
         source_app: Autolaunch.Points.source_app(),
         source_kind: "linked_identity",
         source_event_key: "#{identity.provider}:#{identity.subject}"
       }}
    end
  end

  defp facts(identity, key) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: "linked_identity",
      source_event_key: key,
      account_id: identity.human_account_id,
      actor_kind: "human",
      actor_id: to_string(identity.human_account_id),
      # When this subject was linked to the account; a later sign-in never moves it.
      source_action_at: identity.inserted_at,
      qualified_at: identity.inserted_at,
      evidence_ref: "linked_identity:" <> identity.id,
      evidence: %{"subject_key" => key}
    }
  end
end
