defmodule Autolaunch.AuctionLimitTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.LaunchOperation
  alias Autolaunch.TestSupport

  @wallet "0x1111111111111111111111111111111111111111"
  @hash "0x" <> String.duplicate("ab", 32)
  @unprojected "0x2222222222222222222222222222222222222222"

  test "an account with zero auctions can prepare" do
    account = account!()
    draft = draft!(account)

    assert {:ok, operation} = prepare(account, draft)
    assert operation.state == :prepared
    assert Autolaunch.auctions_prepared_by(account.id) == 0
  end

  test "prepare fails with the named limit once the account has an auction" do
    account = account!()
    draft = draft!(account)
    TestSupport.project_auction(creator_human_account_id: account.id)

    assert {:error, error} = prepare(account, draft)
    assert auction_limit_reached?(error)
    assert Autolaunch.auctions_prepared_by(account.id) == 1
  end

  test "auctions_prepared_by counts auction rows and unprojected chain_verified operations" do
    account = account!()
    assert Autolaunch.auctions_prepared_by(account.id) == 0

    draft = draft!(account)
    {:ok, prepared} = prepare(account, draft)
    {:ok, dispatched} = update(prepared, :claim_dispatch)
    {:ok, submitted} = update(dispatched, :bind_hash, %{launch_transaction_hash: @hash})

    {:ok, _verified} =
      update(submitted, :record_chain_verified, %{result: %{"auction" => @unprojected}})

    assert Autolaunch.auctions_prepared_by(account.id) == 1

    TestSupport.project_auction(creator_human_account_id: account.id)
    assert Autolaunch.auctions_prepared_by(account.id) == 2
  end

  defp account! do
    Accounts.register_verified!(
      "did:privy:auction-limit:#{Elixir.System.unique_integer([:positive])}",
      @wallet,
      [@wallet],
      actor: %System{}
    )
  end

  defp draft!(account) do
    Autolaunch.create_launch_draft!(%{}, actor: %Human{human_account_id: account.id})
  end

  defp prepare(account, draft) do
    LaunchOperation
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        action_id: String.pad_leading("a", 64, "0"),
        envelope: %{"arguments" => %{}},
        signer: @wallet,
        step: :launch,
        human_account_id: account.id,
        launch_draft_id: draft.id
      },
      actor: %System{}
    )
    |> Ash.create(actor: %System{})
  end

  defp update(operation, action, input \\ %{}) do
    operation
    |> Ash.Changeset.for_update(action, input, actor: %System{})
    |> Ash.update(actor: %System{})
  end

  defp auction_limit_reached?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidArgument{field: :human_account_id, vars: vars} ->
        vars[:code] == :auction_limit_reached or vars["code"] == :auction_limit_reached

      _other ->
        false
    end)
  end

  defp auction_limit_reached?(_error), do: false
end
