defmodule Autolaunch.Accounts.VerifiedSessionLinkedIdentityTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{Accounts, VerifiedPrivyIdentity}
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.{Human, System}

  test "session refresh adds and removes verified social identities" do
    verified = verified_identity("reconcile", [social(:x, "x-42", "regent")])

    assert {:ok, account, []} = VerifiedSession.establish(verified)

    assert {:ok, [%{provider: :x, subject: "x-42", username: "regent"}]} =
             Accounts.list_my_linked_identities(actor: %Human{human_account_id: account.id})

    assert {:ok, ^account, []} =
             VerifiedSession.establish(%{verified | linked_socials: []})

    assert {:ok, []} =
             Accounts.list_my_linked_identities(actor: %Human{human_account_id: account.id})
  end

  test "session refresh leaves ENS and World identities untouched" do
    verified = verified_identity("preserve", [social(:github, "github-7", "regents-ai")])
    assert {:ok, account, []} = VerifiedSession.establish(verified)

    for {provider, subject} <- [ens: "regent.eth", world: "world-nullifier"] do
      assert {:ok, _identity} =
               Accounts.upsert_linked_identity(
                 provider,
                 subject,
                 subject,
                 nil,
                 DateTime.utc_now(),
                 %{},
                 account.id,
                 actor: %System{}
               )
    end

    assert {:ok, ^account, []} =
             VerifiedSession.establish(%{verified | linked_socials: []})

    assert {:ok, identities} =
             Accounts.list_linked_identities_for_account(account.id, actor: %System{})

    assert Enum.map(identities, & &1.provider) == [:ens, :world]
  end

  test "a subject owned by another account is skipped without ending the session" do
    assert {:ok, owner, []} =
             VerifiedSession.establish(
               verified_identity("conflict-owner", [social(:farcaster, "12345", "owner")])
             )

    assert {:ok, other, [:farcaster]} =
             VerifiedSession.establish(
               verified_identity("conflict-other", [social(:farcaster, "12345", "other")])
             )

    assert owner.id != other.id
    assert VerifiedSession.current?(other)
    assert {:ok, []} = Accounts.list_linked_identities_for_account(other.id, actor: %System{})
  end

  test "a subject conflict preserves the existing provider row and reports the conflict" do
    verified = verified_identity("preserve-conflict", [social(:x, "x-old", "old-user")])
    assert {:ok, account, []} = VerifiedSession.establish(verified)

    assert {:ok, _owner, []} =
             VerifiedSession.establish(
               verified_identity("preserve-conflict-owner", [
                 social(:x, "x-shared", "shared-user")
               ])
             )

    assert {:ok, ^account, [:x]} =
             VerifiedSession.establish(%{
               verified
               | linked_socials: [social(:x, "x-shared", "shared-user")]
             })

    assert {:ok, [%{provider: :x, subject: "x-old", username: "old-user"}]} =
             Accounts.list_linked_identities_for_account(account.id, actor: %System{})
  end

  test "the first valid entry wins when a token repeats a provider" do
    assert {:ok, owner, []} =
             VerifiedSession.establish(
               verified_identity("duplicate-provider-owner", [
                 social(:github, "github-second", "second-user")
               ])
             )

    assert {:ok, account, []} =
             VerifiedSession.establish(
               verified_identity("duplicate-provider", [
                 social(:github, "github-first", "first-user"),
                 social(:github, "github-second", "second-user")
               ])
             )

    assert {:ok, [%{provider: :github, subject: "github-first", username: "first-user"}]} =
             Accounts.list_linked_identities_for_account(account.id, actor: %System{})

    assert {:ok, %{human_account_id: owner_id}} =
             Accounts.get_linked_identity_by_subject(:github, "github-second", actor: %System{})

    assert owner_id == owner.id
  end

  test "a conflicted present provider survives while absent providers are pruned" do
    verified =
      verified_identity("conflict-pruning", [
        social(:x, "x-pruning-old", "old-user"),
        social(:github, "github-pruning-old", "old-org")
      ])

    assert {:ok, account, []} = VerifiedSession.establish(verified)

    assert {:ok, _owner, []} =
             VerifiedSession.establish(
               verified_identity("conflict-pruning-owner", [
                 social(:x, "x-pruning-shared", "shared-user")
               ])
             )

    assert {:ok, ^account, [:x]} =
             VerifiedSession.establish(%{
               verified
               | linked_socials: [
                   social(:x, "x-pruning-shared", "shared-user"),
                   social(:farcaster, "98765", "new-caster")
                 ]
             })

    assert {:ok, identities} =
             Accounts.list_linked_identities_for_account(account.id, actor: %System{})

    assert Map.new(identities, &{&1.provider, &1.subject}) == %{
             x: "x-pruning-old",
             farcaster: "98765"
           }
  end

  defp verified_identity(suffix, linked_socials) do
    wallet_suffix =
      Elixir.System.unique_integer([:positive]) |> rem(1_000_000) |> Integer.to_string()

    wallet = "0x" <> String.pad_leading(wallet_suffix, 40, "0")

    %VerifiedPrivyIdentity{
      privy_user_id: "did:privy:linked-session:#{suffix}:#{wallet_suffix}",
      session_id: "session-#{suffix}",
      wallet_address: wallet,
      wallet_addresses: [wallet],
      linked_socials: linked_socials
    }
  end

  defp social(provider, subject, username) do
    %{provider: provider, subject: subject, username: username, display_name: nil}
  end
end
