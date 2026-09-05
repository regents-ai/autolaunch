defmodule Autolaunch.Accounts.LinkedIdentityTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  test "one provider belongs to one account and one subject belongs to one account" do
    first = account!("identity-first")
    second = account!("identity-second")
    actor = %System{}

    assert {:ok, identity} = upsert(:x, "x-subject", "regent", first.id, actor)
    assert identity.human_account_id == first.id

    assert {:ok, updated} = upsert(:x, "new-x-subject", "regent-new", first.id, actor)
    assert updated.id == identity.id
    assert updated.subject == "new-x-subject"

    assert {:error, %Ash.Error.Invalid{}} =
             upsert(:x, "new-x-subject", "other-regent", second.id, actor)

    assert {:ok, github} =
             upsert(:github, "new-x-subject", "regents-ai", second.id, actor)

    assert github.provider == :github
  end

  test "writes require the exact system actor" do
    account = account!("identity-policy")

    for actor <- [nil, %Human{human_account_id: account.id}, %{role: :system}, %{rail: :agent}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               upsert(:x, "forbidden-#{inspect(actor)}", "forbidden", account.id, actor)
    end
  end

  test "read_mine returns only the acting human's verified identities" do
    first = account!("identity-scope-first")
    second = account!("identity-scope-second")
    system = %System{}
    first_actor = %Human{human_account_id: first.id}
    second_actor = %Human{human_account_id: second.id}

    assert {:ok, _identity} = upsert(:x, "scope-x", "scope-x", first.id, system)
    assert {:ok, _identity} = upsert(:github, "scope-github", "scope-github", second.id, system)

    assert {:ok, [%{provider: :x}]} = Accounts.list_my_linked_identities(actor: first_actor)
    assert {:ok, [%{provider: :github}]} = Accounts.list_my_linked_identities(actor: second_actor)

    for actor <- [nil, %{role: :human, human_account_id: first.id}, system] do
      assert {:error, _error} = Accounts.list_my_linked_identities(actor: actor)
    end
  end

  defp account!(suffix) do
    Accounts.register_verified!(
      "did:privy:linked-identity:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
      nil,
      [],
      actor: %System{}
    )
  end

  defp upsert(provider, subject, username, human_account_id, actor) do
    Accounts.upsert_linked_identity(
      provider,
      subject,
      username,
      nil,
      DateTime.utc_now(),
      %{},
      human_account_id,
      actor: actor
    )
  end
end
