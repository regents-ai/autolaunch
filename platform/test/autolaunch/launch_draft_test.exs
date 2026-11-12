defmodule Autolaunch.LaunchDraftTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.LaunchDraft

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
                 "website" => "not a complete URL yet"
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

  test "a draft refuses hidden characters in a field, and a website must be a full link to launch" do
    actor = %Human{human_account_id: account!("hidden-text").id}
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    for {field, value} <- [{"name", "Bad\u0000Name"}, {"description", "\u202Eevil"}] do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: refused, message: message}]}} =
               Autolaunch.autosave_launch_token_details(draft, %{field => value}, actor: actor)

      assert {to_string(refused), message} == {field, "Remove the hidden characters from this."}
    end

    assert {:ok, lines} =
             Autolaunch.autosave_launch_token_details(
               draft,
               %{"description" => "Line one\nLine two", "website" => "javascript:alert(1)"},
               actor: actor
             )

    assert :website in LaunchDraft.missing_token_details(lines)

    assert {:ok, linked} =
             Autolaunch.autosave_launch_token_details(
               lines,
               %{"website" => "https://example.com"},
               actor: actor
             )

    refute :website in LaunchDraft.missing_token_details(linked)
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
