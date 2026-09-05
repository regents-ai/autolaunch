defmodule Autolaunch.ListingFilterTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{Auction, Token}
  alias Autolaunch.TestSupport

  test "project_lab rejects a nil creator" do
    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.project_lab_auction(
               %{
                 projection_id: Ash.UUID.generate(),
                 title: "No creator",
                 featured: false,
                 state: :created,
                 creator_human_account_id: nil
               },
               actor: %System{}
             )
  end

  test "public Auction and Token reads return only creator-owned rows" do
    hidden_id = insert_null_creator_auction!()
    visible = TestSupport.project_auction(title: "Visible", featured: true, state: :active)
    graduated_at = DateTime.utc_now()

    hidden_token =
      TestSupport.project_token(
        auction_id: hidden_id,
        name: "Hidden Token",
        symbol: "HID",
        subject_id: "subject:hidden",
        graduated_at: graduated_at,
        top_rank: 1
      )

    visible_token =
      TestSupport.project_token(
        auction_id: visible.id,
        name: "Visible Token",
        symbol: "VIS",
        subject_id: "subject:visible",
        graduated_at: graduated_at,
        top_rank: 2
      )

    Autolaunch.set_subject_token_price!(hidden_token, "9", "test", graduated_at, actor: %System{})

    Autolaunch.set_subject_token_price!(visible_token, "1", "test", graduated_at,
      actor: %System{}
    )

    assert_ids(Ash.read!(Ash.Query.for_read(Auction, :read)), [visible.id])
    assert_ids(Autolaunch.list_auctions!(), [visible.id])
    assert_ids(Autolaunch.list_recent_auctions!(), [visible.id])
    assert_ids(Autolaunch.list_featured_auctions!(), [visible.id])
    assert_ids(Autolaunch.list_active_launchpad_auctions!(""), [visible.id])
    assert_ids(Autolaunch.list_explore_launchpad_auctions!(""), [visible.id])
    assert {:ok, %Auction{id: visible_id}} = Autolaunch.get_public_auction(visible.id)
    assert visible_id == visible.id
    assert {:ok, nil} = Autolaunch.get_public_auction(hidden_id)

    assert_ids(Ash.read!(Ash.Query.for_read(Token, :read)), [visible_token.id])
    assert_ids(Autolaunch.list_tokens!(), [visible_token.id])
    assert_ids(Autolaunch.list_top_tokens!(), [visible_token.id])
    assert_ids(Autolaunch.list_recently_graduated_tokens!(), [visible_token.id])
    assert_ids(Autolaunch.list_graduated_launchpad_tokens!(""), [visible_token.id])
    assert_ids(Autolaunch.list_explore_launchpad_tokens!(""), [visible_token.id])
    assert_ids(Autolaunch.list_subject_tokens!("subject:visible"), [visible_token.id])
    assert Autolaunch.list_subject_tokens!("subject:hidden") == []
    assert {:ok, %Token{id: visible_token_id}} = Autolaunch.get_public_token(visible_token.id)
    assert visible_token_id == visible_token.id
    assert {:ok, nil} = Autolaunch.get_public_token(hidden_token.id)

    assert {:ok, %Token{id: price_id}} =
             Autolaunch.get_latest_subject_token_price("subject:visible")

    assert price_id == visible_token.id
    assert {:ok, nil} = Autolaunch.get_latest_subject_token_price("subject:hidden")
  end

  defp insert_null_creator_auction! do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    # The resource and migration refuse NULL; AE6 still has to prove a
    # beneath-the-resource row is filtered from every public read.
    {:ok, _} =
      Autolaunch.Repo.query(
        "ALTER TABLE auctions ALTER COLUMN creator_human_account_id DROP NOT NULL"
      )

    {1, nil} =
      Autolaunch.Repo.insert_all("auctions", [
        %{
          id: Ecto.UUID.dump!(id),
          title: "Hidden",
          featured: true,
          state: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  defp assert_ids(records, expected_ids) do
    assert Enum.map(records, & &1.id) == expected_ids
  end
end
