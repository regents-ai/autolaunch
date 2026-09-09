defmodule Autolaunch.Stocks.LaunchDraftTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  # AT11: a Stocks draft is private to the account that owns it.
  test "another account can neither read nor update a Stocks draft" do
    owner = %Human{human_account_id: account!("owner").id}
    other = %Human{human_account_id: account!("other").id}

    draft = Autolaunch.create_stocks_launch_draft!(%{}, actor: owner)

    assert {:ok, %{name: "Mine"}} =
             Autolaunch.autosave_stocks_token_details(draft, %{"name" => "Mine"}, actor: owner)

    assert {:ok, nil} = Autolaunch.get_my_stocks_launch_draft_by_id(draft.id, actor: other)
    assert {:ok, nil} = Autolaunch.get_my_stocks_launch_draft(actor: other)

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.autosave_stocks_token_details(draft, %{"name" => "Stolen"}, actor: other)

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.autosave_stocks_revenue(
               draft,
               %{"fee_administrator" => "0x2222222222222222222222222222222222222222"},
               actor: other
             )

    assert {:ok, %{name: "Mine", fee_administrator: nil}} =
             Autolaunch.get_my_stocks_launch_draft_by_id(draft.id, actor: owner)
  end

  defp account!(suffix) do
    Accounts.register_verified!(
      "did:privy:stocks-draft:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
      nil,
      [],
      actor: %System{}
    )
  end
end
