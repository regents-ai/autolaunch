defmodule Autolaunch.Accounts.XConnectionTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  test "one row belongs to each Human role while the same X user may fill any role" do
    first = account!("first")
    second = account!("second")
    first_actor = human(first)
    second_actor = human(second)

    profile = begin!(first_actor, :profile)
    company = begin!(first_actor, :company)
    other_profile = begin!(second_actor, :profile)

    for {connection, actor} <- [
          {profile, first_actor},
          {company, first_actor},
          {other_profile, second_actor}
        ] do
      assert {:ok, completed} =
               Accounts.complete_x_connection_attempt(
                 connection,
                 %{
                   x_user_id: "x-user-42",
                   username: "same_creator",
                   display_name: "Same Creator",
                   avatar_url: "https://images.example.test/same.png",
                   verified_at: DateTime.utc_now(),
                   next_generation: Ash.UUID.generate()
                 },
                 actor: actor
               )

      assert completed.attempt_state == nil
      assert completed.attempt_verifier == nil
      assert completed.attempt_expires_at == nil
      assert completed.attempt_generation
    end

    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.begin_x_connection_attempt(attempt(:profile), actor: first_actor)

    assert {:ok, public} = Accounts.list_public_x_connections([first.id, second.id])
    assert length(public) == 3
    assert Enum.uniq(Enum.map(public, & &1.x_user_id)) == ["x-user-42"]
  end

  test "owner reads are isolated and explicit disconnect clears only public identity" do
    owner = account!("owner")
    other = account!("other")
    owner_actor = human(owner)
    other_actor = human(other)

    connection = begin!(owner_actor, :profile)

    assert {:ok, connection} =
             Accounts.complete_x_connection_attempt(
               connection,
               %{
                 x_user_id: "x-owner",
                 username: "owner_profile",
                 display_name: "Owner Profile",
                 avatar_url: nil,
                 verified_at: DateTime.utc_now(),
                 next_generation: Ash.UUID.generate()
               },
               actor: owner_actor
             )

    assert {:ok, nil} = Accounts.get_my_x_connection(:profile, actor: other_actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.disconnect_x_connection(
               connection,
               1,
               Ash.UUID.generate(),
               actor: other_actor
             )

    assert {:ok, disconnected} =
             Accounts.disconnect_x_connection(
               connection,
               1,
               Ash.UUID.generate(),
               actor: owner_actor
             )

    assert disconnected.x_user_id == nil
    assert disconnected.username == nil
    assert disconnected.display_name == nil
    assert disconnected.avatar_url == nil
    assert disconnected.verified_at == nil
    assert disconnected.attempt_generation == nil
    assert disconnected.intent_generation

    assert {:ok, []} = Accounts.list_public_x_connections([owner.id])
  end

  defp begin!(actor, role), do: Accounts.begin_x_connection_attempt!(attempt(role), actor: actor)

  defp attempt(role) do
    %{
      role: role,
      attempt_state: "state-#{Ash.UUID.generate()}",
      attempt_verifier: "verifier-#{Ash.UUID.generate()}",
      attempt_generation: Ash.UUID.generate(),
      attempt_expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      intent_sequence: 1,
      intent_generation: Ash.UUID.generate()
    }
  end

  defp account!(suffix) do
    Accounts.register_verified!(
      "did:privy:x-connection:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
      nil,
      [],
      actor: %System{}
    )
  end

  defp human(account), do: %Human{human_account_id: account.id}
end
