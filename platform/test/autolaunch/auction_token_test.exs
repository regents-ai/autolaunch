defmodule Autolaunch.AuctionTokenTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.TestSupport

  test "public auction reads separate recent and explicitly featured records" do
    recent =
      TestSupport.project_auction(
        title: "Recent auction",
        summary: "A newly created launch.",
        featured: false,
        state: :created,
        opened_at: nil
      )

    featured =
      TestSupport.project_auction(
        title: "Featured auction",
        summary: "An editorially featured launch.",
        featured: true,
        state: :active,
        opened_at: DateTime.utc_now()
      )

    assert {:ok, recent_records} = Autolaunch.list_recent_auctions()

    recent_ids = MapSet.new(Enum.map(recent_records, & &1.id))
    assert MapSet.subset?(MapSet.new([recent.id, featured.id]), recent_ids)

    assert {:ok, [featured_record]} = Autolaunch.list_featured_auctions()
    assert featured_record.id == featured.id
    assert {:ok, public} = Autolaunch.get_public_auction(recent.id)
    assert public.title == "Recent auction"
  end

  test "top and recently graduated tokens require explicit public facts" do
    ranked_auction = auction!()
    unranked_auction = auction!()
    graduated_at = DateTime.utc_now()

    ranked =
      TestSupport.project_token(
        auction_id: ranked_auction.id,
        name: "Regent One",
        symbol: "RONE",
        summary: "A graduated token.",
        graduated_at: graduated_at,
        top_rank: 1
      )

    unranked =
      TestSupport.project_token(
        auction_id: unranked_auction.id,
        name: "Regent Two",
        symbol: "RTWO",
        graduated_at: graduated_at
      )

    assert {:ok, [top]} = Autolaunch.list_top_tokens()
    assert top.id == ranked.id

    assert {:ok, graduated} = Autolaunch.list_recently_graduated_tokens()
    assert MapSet.new(Enum.map(graduated, & &1.id)) == MapSet.new([ranked.id, unranked.id])
    assert {:ok, nil} = Autolaunch.get_public_token(Ash.UUID.generate())
  end

  test "project_lab rejects missing and lookalike system actors" do
    creator = account!(Elixir.System.unique_integer([:positive]))

    for actor <- [nil, %{role: :system}, %{role: :human, human_account_id: 1}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Autolaunch.project_lab_auction(
                 %{
                   projection_id: Ash.UUID.generate(),
                   title: "Nope",
                   featured: false,
                   state: :created,
                   creator_human_account_id: creator.id
                 },
                 actor: actor
               )
    end
  end

  test "launchpad search treats adapter wildcards and Unicode as literal text" do
    nonce = Integer.to_string(Elixir.System.unique_integer([:positive]))

    percent = projected_auction!("Percent %#{nonce}", "PL#{nonce}")
    underscore = projected_auction!("Underscore _#{nonce}", "UL#{nonce}")
    slash = projected_auction!("Slash \\#{nonce}", "SL#{nonce}")
    unicode = projected_auction!("猫の市場 #{nonce}", "CAT#{nonce}")

    for {query, expected} <- [
          {"%#{nonce}", percent},
          {"_#{nonce}", underscore},
          {"\\#{nonce}", slash},
          {"猫の市場 #{nonce}", unicode}
        ] do
      assert {:ok, records} = Autolaunch.list_active_launchpad_auctions(query)
      assert Enum.map(records, & &1.id) == [expected.id]
    end
  end

  test "launchpad search covers presentation, mixed-case addresses, X identities and bounds" do
    nonce = Elixir.System.unique_integer([:positive])
    creator = account!(nonce)
    connect_x!(creator, "creator#{nonce}", "Launch Creator #{nonce}")
    address = "0xAbCdEf0000000000000000000000000000000001"

    auction =
      projected_auction!("Searchable Launch #{nonce}", "FIND#{nonce}",
        summary: "One exact description #{nonce}",
        address: address,
        creator_human_account_id: creator.id
      )

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Graduated Search #{nonce}",
        symbol: "GRAD#{nonce}",
        summary: "Token description #{nonce}",
        graduated_at: DateTime.utc_now()
      )

    for query <- [
          "SEARCHABLE LAUNCH #{nonce}",
          "find#{nonce}",
          "description #{nonce}",
          String.upcase(address)
        ] do
      assert {:ok, records} = Autolaunch.list_active_launchpad_auctions(query)
      assert Enum.any?(records, &(&1.id == auction.id))
    end

    assert {:ok, by_creator} = Autolaunch.list_active_launchpad_auctions("CREATOR#{nonce}")

    assert Enum.any?(by_creator, &(&1.id == auction.id))

    for query <- [
          "SEARCHABLE LAUNCH #{nonce}",
          "find#{nonce}",
          "one exact description #{nonce}",
          String.upcase(address),
          "launch creator #{nonce}"
        ] do
      assert {:ok, records} = Autolaunch.list_graduated_launchpad_tokens(query)
      assert Enum.any?(records, &(&1.id == token.id))
    end

    for divergent_legacy_query <- ["GRAD#{nonce}", "token description #{nonce}"] do
      assert {:ok, records} =
               Autolaunch.list_graduated_launchpad_tokens(divergent_legacy_query)

      refute Enum.any?(records, &(&1.id == token.id))
    end

    assert {:ok, active} = Autolaunch.list_active_launchpad_auctions("")
    assert length(active) <= 8

    assert {:ok, explored} = Autolaunch.list_explore_launchpad_auctions("")
    assert length(explored) <= 24

    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.list_active_launchpad_auctions(String.duplicate("x", 81))
  end

  test "launchpad creator search remains complete beyond one hundred matching X identities" do
    nonce = Elixir.System.unique_integer([:positive])
    username = "sharedcreator#{nonce}"

    Enum.each(1..100, fn index ->
      nonce
      |> account!(index)
      |> connect_x!(username, "Shared creator")
    end)

    creator = account!(nonce, 101)
    connect_x!(creator, username, "Shared creator")

    auction =
      projected_auction!("Target beyond old X prefilter #{nonce}", "OVER#{nonce}",
        creator_human_account_id: creator.id
      )

    assert {:ok, records} = Autolaunch.list_active_launchpad_auctions(username)
    assert Enum.any?(records, &(&1.id == auction.id))
  end

  defp auction! do
    TestSupport.project_auction(
      title: "Token auction",
      state: :graduated,
      opened_at: DateTime.utc_now()
    )
  end

  defp projected_auction!(title, symbol, options \\ []) do
    TestSupport.project_auction(
      title: title,
      symbol: symbol,
      summary: Keyword.get(options, :summary),
      address: Keyword.get(options, :address),
      creator_human_account_id: Keyword.get(options, :creator_human_account_id),
      featured: false,
      state: :active,
      current_clearing_price: "1"
    )
  end

  defp account!(nonce, index \\ 0) do
    wallet_seed = nonce * 1_000 + index
    wallet = "0x" <> String.pad_leading(Integer.to_string(wallet_seed, 16), 40, "0")

    Accounts.register_verified!(
      "did:privy:auction-search:#{nonce}:#{index}",
      wallet,
      [wallet],
      actor: %System{}
    )
  end

  defp connect_x!(account, username, display_name) do
    actor = %Human{human_account_id: account.id}

    connection =
      Accounts.begin_x_connection_attempt!(
        %{
          role: :profile,
          attempt_state: "state-#{Ash.UUID.generate()}",
          attempt_verifier: "verifier-#{Ash.UUID.generate()}",
          attempt_generation: Ash.UUID.generate(),
          attempt_expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        },
        actor: actor
      )

    Accounts.complete_x_connection_attempt!(
      connection,
      %{
        x_user_id: "id-#{username}",
        username: username,
        display_name: display_name,
        verified_at: DateTime.utc_now(),
        next_generation: Ash.UUID.generate()
      },
      actor: actor
    )
  end
end
