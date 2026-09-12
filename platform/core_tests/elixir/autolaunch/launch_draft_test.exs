defmodule Autolaunch.LaunchDraftTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.{LaunchDraft}

  test "owner autosave persists bounded incomplete text and refuses cross-account writes" do
    owner = account!("autosave-owner")
    other = account!("autosave-other")
    actor = %Human{human_account_id: owner.id}
    other_actor = %Human{human_account_id: other.id}
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, token_partial} =
             Autolaunch.autosave_launch_token_details(
               draft,
               %{
                 "name" => "Partial",
                 "symbol" => "",
                 "description" => "Still writing",
                 "website" => "not a complete URL yet",
                 "required_regent_raised" => "1."
               },
               actor: actor
             )

    assert token_partial.name == "Partial"
    assert token_partial.description == "Still writing"
    refute LaunchDraft.token_details_complete?(token_partial)

    assert {:ok, treasury_partial} =
             Autolaunch.autosave_launch_treasury(
               token_partial,
               %{
                 "treasury" => "0x123",
                 "treasury_path" => "eoa",
                 "eoa_acknowledgement" => "typing"
               },
               actor: actor
             )

    assert treasury_partial.treasury == "0x123"
    assert treasury_partial.eoa_acknowledgement == "typing"
    refute LaunchDraft.treasury_complete?(treasury_partial)

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.autosave_launch_token_details(
               treasury_partial,
               %{"name" => "Stolen"},
               actor: other_actor
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.autosave_launch_token_details(
               treasury_partial,
               %{"description" => String.duplicate("x", 513)},
               actor: actor
             )

    assert {:ok, [persisted]} = Autolaunch.list_my_launch_drafts(actor: actor)
    assert persisted.name == "Partial"
    assert persisted.treasury == "0x123"
  end

  # One private draft per account and chain: the Robinhood draft never shows
  # up as, or overwrites, the Base draft, and each chain re-reads its own.
  test "an account holds one draft per chain" do
    actor = %Human{human_account_id: account!("per-chain").id}

    base = Autolaunch.create_launch_draft!(%{chain: :base}, actor: actor)
    robinhood = Autolaunch.create_launch_draft!(%{chain: :robinhood}, actor: actor)

    assert base.id != robinhood.id
    assert {:ok, %{id: base_id}} = Autolaunch.get_my_account_launch_draft(:base, actor: actor)
    assert base_id == base.id

    assert {:ok, %{id: robinhood_id}} =
             Autolaunch.get_my_account_launch_draft(:robinhood, actor: actor)

    assert robinhood_id == robinhood.id

    assert %{id: ^base_id} = Autolaunch.create_launch_draft!(%{chain: :base}, actor: actor)
  end

  defp account!(suffix) do
    Accounts.register_verified!(
      "did:privy:autolaunch-draft:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
      nil,
      [],
      actor: %System{}
    )
  end
end
