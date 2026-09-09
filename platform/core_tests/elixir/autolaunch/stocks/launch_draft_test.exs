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

    # One stock launch in progress per account: a created Stocks auction of the
    # owner's blocks a new review until it graduates or fails, and never counts
    # for another account.
    auction = "0x" <> String.duplicate("ab", 20)
    account = %{id: owner.human_account_id}

    :ok =
      Autolaunch.Stocks.LabProjection.project_observed(%{
        auction_address: auction,
        creator_human_account_id: owner.human_account_id,
        title: "Mine",
        summary: "A test launch",
        token_symbol: "MINE",
        website: "https://example.com",
        image: "https://example.com/i.png",
        quote_token_address: "0xb200000000000000000000c2e324d24d7eecd1fb",
        quote_token_symbol: "AAPLc",
        quote_token_decimals: 8,
        state: :created,
        treasury_address: "0x" <> String.duplicate("cd", 20)
      })

    assert Autolaunch.active_stocks_auctions_by(owner.human_account_id) == 1
    assert Autolaunch.active_stocks_auctions_by(other.human_account_id) == 0

    attributes = %{
      action_id: String.duplicate("f", 64),
      launch_draft_id: draft.id,
      envelope: %{},
      signer: "0x" <> String.duplicate("11", 20),
      step: :launch
    }

    assert {:error, %Ash.Error.Invalid{errors: [%{vars: [code: :active_stocks_launch_exists]}]}} =
             Autolaunch.Stocks.LaunchOperations.create(account, attributes)

    {:ok, row} =
      Ash.get(Autolaunch.Auction, Autolaunch.LabProjection.auction_id(auction), actor: %System{})

    Ash.update!(row, %{state: :graduated}, action: :refresh_lab_market, actor: %System{})

    assert Autolaunch.active_stocks_auctions_by(owner.human_account_id) == 0

    assert {:ok, %{step: :launch}} =
             Autolaunch.Stocks.LaunchOperations.create(account, attributes)
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
