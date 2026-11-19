defmodule Autolaunch.AccountLinksTest do
  @moduledoc """
  The site's own reads and writes of a person's linked accounts that a sign-in
  and Regent Points use: a sign-in refreshes a link only while it is still
  that subject's, and only the site itself may list or refresh them.
  """
  use Autolaunch.DataCase, async: true

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.{Human, System}

  test "a refresh writes only while the link is still that subject's, and never moves when it was linked" do
    did = did()
    github = social()
    account = sign_in(did, [github])
    {:ok, link} = linked(github.subject)

    assert :ok =
             VerifiedSession.refresh_linked_social(
               link,
               %{username: "renamed", display_name: "Renamed"},
               %System{}
             )

    {:ok, refreshed} = linked(github.subject)
    assert %{username: "renamed", display_name: "Renamed"} = refreshed
    assert DateTime.after?(refreshed.verified_at, link.verified_at)
    assert refreshed.inserted_at == link.inserted_at

    # Another sign-in put a different GitHub account in its place meanwhile.
    other = social()
    sign_in(did, [other])
    {:ok, replaced} = linked(other.subject)
    assert replaced.id == link.id

    assert :ok =
             VerifiedSession.refresh_linked_social(
               refreshed,
               %{username: "stale", display_name: "Stale"},
               %System{}
             )

    assert linked(other.subject) == {:ok, replaced}

    # Another sign-in let it go meanwhile.
    sign_in(did, [])

    assert :ok =
             VerifiedSession.refresh_linked_social(
               replaced,
               %{username: "stale", display_name: "Stale"},
               %System{}
             )

    assert linked(other.subject) == {:ok, nil}

    assert Accounts.list_linked_identities_for_account(account.id, actor: %System{}) ==
             {:ok, []}
  end

  test "a signed-in person, or no one, may not list what Points reads or refresh a link" do
    github = social()
    account = sign_in(did(), [github])
    {:ok, link} = linked(github.subject)
    now = DateTime.utc_now()
    refresh = %{username: "renamed", display_name: "Renamed", verified_at: now, metadata: %{}}

    for actor <- [%Human{human_account_id: account.id}, nil] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.accounts_created_before(now, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.accounts_by_privy_dids([account.privy_user_id], actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.linked_identities_before(:github, now, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.get_connected_x_profile("1", actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.x_profiles_connected_before(now, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.refresh_linked_identity(link, refresh, actor: actor)
    end

    assert linked(github.subject) == {:ok, link}
  end

  defp sign_in(did, socials) do
    wallet = "0x" <> String.slice(Base.encode16(:crypto.hash(:sha, did), case: :lower), 0, 40)

    assert {:ok, account, []} =
             VerifiedSession.establish(%RegentPrivy.Session{
               app_id: "test-app",
               session_id: "test-session",
               privy_user_id: did,
               wallet_address: wallet,
               wallet_addresses: [wallet],
               linked_socials: socials,
               issued_at: :erlang.system_time(:second),
               expires_at: :erlang.system_time(:second) + 3600
             })

    account
  end

  defp linked(subject),
    do: Accounts.get_linked_identity_by_subject(:github, subject, actor: %System{})

  defp did, do: "did:privy:links-" <> Ecto.UUID.generate()

  defp social,
    do: %{
      provider: :github,
      subject: "github-" <> Ecto.UUID.generate(),
      username: "linked",
      display_name: nil
    }
end
