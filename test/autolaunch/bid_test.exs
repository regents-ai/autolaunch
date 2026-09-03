defmodule Autolaunch.BidTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Bid
  alias Autolaunch.TestSupport

  @wallet_a "0xaaaa00000000000000000000000000000000a401"
  @wallet_a_paired "0xaaaa00000000000000000000000000000000a402"
  @wallet_b "0xbbbb00000000000000000000000000000000b401"

  @unsafe_bid_ids [
    slash: "bid/slash",
    query: "bid?query",
    fragment: "bid#fragment",
    percent: "bid%encoded",
    space: "bid identity",
    unicode: "bid-é",
    too_long: String.duplicate("a", 129)
  ]

  test "signed-in reads preserve stored position strings and linked token records" do
    account = account!("resource", @wallet_a, [@wallet_a])
    actor = %Human{human_account_id: account.id}
    auction = auction!("Bid resource auction")

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Bid Token",
        symbol: "BID",
        graduated_at: DateTime.utc_now()
      )

    claimed_at = ~U[2026-07-30 12:30:00.000000Z]

    bid =
      bid!("bid:resource", auction.id, mixedcase(@wallet_a),
        amount: "1000000000000000000",
        max_price: "2500000",
        current_clearing_price: "1750000",
        estimated_tokens_if_end_now: "42000000000000000000",
        status: "claimed",
        claimed_at: claimed_at
      )

    assert bid.owner_address == @wallet_a

    assert {:ok, [position]} = Autolaunch.list_my_bid_positions(actor: actor)
    assert position.bid_id == "bid:resource"
    assert position.auction_id == auction.id
    assert position.auction.id == auction.id
    assert position.token.id == token.id
    assert position.amount == "1000000000000000000"
    assert position.max_price == "2500000"
    assert position.current_clearing_price == "1750000"
    assert position.estimated_tokens_if_end_now == "42000000000000000000"
    assert position.status == "claimed"
    assert position.claimed_at == claimed_at

    assert {:ok, []} = Autolaunch.list_my_returnable_bid_positions(actor: actor)
    assert {:ok, [claimed]} = Autolaunch.list_my_claimed_token_positions(actor: actor)
    assert claimed.bid_id == bid.bid_id
    assert claimed.token.id == token.id
  end

  test "every human read path excludes positions owned by another user's wallets" do
    account_a = account!("policy-a", @wallet_a, [@wallet_a, @wallet_a_paired])
    account_b = account!("policy-b", @wallet_b, [@wallet_b])
    actor_a = %Human{human_account_id: account_a.id}
    actor_b = %Human{human_account_id: account_b.id}
    auction = auction!("Policy isolation auction")

    own_returnable =
      bid!("bid:own:returnable", auction.id, mixedcase(@wallet_a), status: "returnable")

    own_claimed =
      bid!("bid:own:claimed", auction.id, mixedcase(@wallet_a_paired),
        status: "claimed",
        claimed_at: DateTime.utc_now()
      )

    other =
      bid!("bid:other:returnable", auction.id, @wallet_b, status: "returnable")

    assert {:ok, positions_a} = Autolaunch.list_my_bid_positions(actor: actor_a)
    assert ids(positions_a) == MapSet.new([own_returnable.bid_id, own_claimed.bid_id])
    refute other.bid_id in ids_list(positions_a)

    assert {:ok, returnable_a} = Autolaunch.list_my_returnable_bid_positions(actor: actor_a)
    assert ids(returnable_a) == MapSet.new([own_returnable.bid_id])
    refute other.bid_id in ids_list(returnable_a)

    assert {:ok, claimed_a} = Autolaunch.list_my_claimed_token_positions(actor: actor_a)
    assert ids(claimed_a) == MapSet.new([own_claimed.bid_id])
    refute other.bid_id in ids_list(claimed_a)

    assert {:ok, positions_b} = Autolaunch.list_my_bid_positions(actor: actor_b)
    assert ids(positions_b) == MapSet.new([other.bid_id])

    assert {:ok, returnable_b} = Autolaunch.list_my_returnable_bid_positions(actor: actor_b)
    assert ids(returnable_b) == MapSet.new([other.bid_id])

    assert {:ok, []} = Autolaunch.list_my_claimed_token_positions(actor: actor_b)

    assert {:ok, direct_a} =
             Ash.read(Bid, action: :mine, actor: actor_a, domain: Autolaunch)

    assert ids(direct_a) == MapSet.new([own_returnable.bid_id, own_claimed.bid_id])
    refute other.bid_id in ids_list(direct_a)
  end

  test "signed-out and stale-wallet actors cannot read holdings" do
    auction = auction!("Denied holdings auction")
    bid!("bid:denied", auction.id, @wallet_a)

    for read <- [
          &Autolaunch.list_my_bid_positions/1,
          &Autolaunch.list_my_returnable_bid_positions/1,
          &Autolaunch.list_my_claimed_token_positions/1
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = read.([])
    end

    account = account!("stale", @wallet_a, [@wallet_a])
    assert {:ok, _account} = Accounts.refresh_verified(account, nil, [], actor: %System{})
    actor = %Human{human_account_id: account.id}

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.list_my_bid_positions(actor: actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.list_my_returnable_bid_positions(actor: actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.list_my_claimed_token_positions(actor: actor)
  end

  test "canonical bid identity edges round-trip and unsafe values are rejected" do
    account = account!("identity", @wallet_a, [@wallet_a])
    actor = %Human{human_account_id: account.id}
    auction = auction!("Bid identity auction")
    edge_ids = ["Z", "A._:-" <> String.duplicate("x", 123)]

    for bid_id <- edge_ids do
      assert bid!(bid_id, auction.id, @wallet_a).bid_id == bid_id
    end

    assert {:ok, positions} = Autolaunch.list_my_bid_positions(actor: actor)
    assert ids(positions) == MapSet.new(edge_ids)

    for {unsafe_class, bid_id} <- @unsafe_bid_ids do
      assert {:error, %Ash.Error.Invalid{} = error} =
               import_bid(bid_id, auction.id, @wallet_a)

      message = Exception.message(error)
      assert message =~ "bid_id", "#{unsafe_class} did not identify the invalid field"

      assert message =~ "must match the pattern" or
               message =~ "length must be less than or equal to 128",
             "#{unsafe_class} did not explain the canonical ID format"
    end
  end

  test "bid identity is unique and imports require the real system actor" do
    auction = auction!("Bid import boundary")
    bid = bid!("bid:unique", auction.id, @wallet_a)

    assert {:error, %Ash.Error.Invalid{}} = import_bid(bid.bid_id, auction.id, @wallet_a)

    for actor <- [nil, %{role: :system}, %Human{human_account_id: 1}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               import_bid("bid:forbidden", auction.id, @wallet_a, actor: actor)
    end
  end

  defp account!(suffix, primary, addresses) do
    Accounts.register_verified!(
      "did:privy:bid-#{suffix}",
      primary,
      addresses,
      actor: %System{}
    )
  end

  defp auction!(title) do
    TestSupport.project_auction(title: title, state: :active, opened_at: DateTime.utc_now())
  end

  defp bid!(bid_id, auction_id, owner_address, attrs \\ []) do
    case import_bid(bid_id, auction_id, owner_address, attrs) do
      {:ok, bid} -> bid
      {:error, error} -> raise error
    end
  end

  defp import_bid(bid_id, auction_id, owner_address, attrs \\ []) do
    Autolaunch.import_bid_position(
      bid_id,
      auction_id,
      owner_address,
      Keyword.get(attrs, :amount, "10"),
      Keyword.get(attrs, :max_price, "2"),
      Keyword.get(attrs, :current_clearing_price, "1"),
      Keyword.get(attrs, :estimated_tokens_if_end_now, "5"),
      Keyword.get(attrs, :status, "active"),
      Keyword.get(attrs, :exited_at),
      Keyword.get(attrs, :claimed_at),
      actor: Keyword.get(attrs, :actor, %System{})
    )
  end

  defp ids(records), do: records |> ids_list() |> MapSet.new()
  defp ids_list(records), do: Enum.map(records, & &1.bid_id)
  defp mixedcase("0x" <> address), do: "0x" <> String.upcase(address)
end
