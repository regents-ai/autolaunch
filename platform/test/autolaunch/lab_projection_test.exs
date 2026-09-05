defmodule Autolaunch.LabProjectionTest do
  use AutolaunchWeb.ConnCase, async: false

  require Ash.Query

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  alias Autolaunch.{
    Auction,
    Bid,
    LabProjection,
    LaunchDraft,
    LaunchJob,
    LaunchOperation,
    Subject,
    Token
  }

  @domain Autolaunch
  @actor %System{}
  @wallet "0x1111111111111111111111111111111111111111"
  @factory "0x2222222222222222222222222222222222222222"
  @hook "0x3333333333333333333333333333333333333333"
  @regent "0x4444444444444444444444444444444444444444"
  @auction "0x5555555555555555555555555555555555555555"
  @subject "0x6666666666666666666666666666666666666666"
  @escrow "0x7777777777777777777777777777777777777777"
  @treasury "0x8888888888888888888888888888888888888888"
  @splitter "0x9999999999999999999999999999999999999999"
  @receiver "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  test "a verified local launch and bid project once under exact deterministic identities" do
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())

    [auction] = all(Auction)
    [subject] = all(Subject)
    [launch] = all(LaunchJob)

    assert auction.id == LabProjection.auction_id(@auction)
    assert auction.state == :active
    assert auction.auction_address == @auction
    assert auction.treasury_address == @treasury
    assert auction.quote_token_address == @regent

    assert subject.subject_id == LabProjection.subject_identity(@subject)
    assert subject.chain_id == 31_337
    assert subject.token_address == @subject
    assert subject.treasury_address == @treasury

    assert launch.job_id == LabProjection.launch_identity("17")
    assert launch.auction_id == auction.id
    assert launch.chain_id == 31_337
    assert launch.token_symbol == "LOCAL"
    assert launch.hook_address == @hook

    assert :ok = LabProjection.project_bid(bid_operation(auction.id), bid_result())
    assert :ok = LabProjection.project_bid(bid_operation(auction.id), bid_result())

    [bid] = all(Bid)
    assert bid.bid_id == LabProjection.bid_identity(@auction, "9")
    assert bid.auction_id == auction.id
    assert bid.owner_address == @wallet
    assert bid.auction_address == @auction
    assert bid.onchain_bid_id == "9"
  end

  test "launch presentation and creator come only from the immutable operation envelope" do
    account = account!("immutable-presentation")
    actor = %Human{human_account_id: account.id}

    draft =
      Autolaunch.create_launch_draft!(
        %{
          "name" => "Mutable draft",
          "symbol" => "MUT",
          "description" => "Before review",
          "website" => "https://mutable.example/before",
          "required_regent_raised" => "1"
        },
        actor: actor
      )

    operation =
      Ash.Seed.seed!(LaunchOperation, %{
        action_id: String.duplicate("a", 64),
        envelope: launch_operation(account.id).envelope,
        signer: @wallet,
        step: :launch,
        state: :submitted,
        human_account_id: account.id,
        launch_draft_id: draft.id
      })

    assert {:ok, %LaunchDraft{}} =
             Autolaunch.autosave_launch_token_details(
               draft,
               %{
                 "name" => "Changed after wallet review",
                 "symbol" => "NEW",
                 "description" => "This mutable copy must never project.",
                 "website" => "https://mutable.example/after",
                 "required_regent_raised" => "2"
               },
               actor: actor
             )

    assert :ok = LabProjection.project_launch(operation, launch_result())

    auction = one(Auction)
    assert auction.title == "Local Regent"
    assert auction.summary == "A local fork launch."
    assert auction.token_symbol == "LOCAL"
    assert auction.website == "https://example.test/local"
    assert auction.image == "https://example.test/local.png"
    assert auction.creator_human_account_id == account.id
  end

  test "out-of-order position receipts cannot rewind claimed or graduated chain state" do
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())
    auction_id = LabProjection.auction_id(@auction)
    assert :ok = LabProjection.project_bid(bid_operation(auction_id), bid_result())
    [bid] = all(Bid)

    exit = %{
      "bid_status" => "exited",
      "exited" => true,
      "claimed" => false,
      "current_clearing_price" => "1.25"
    }

    assert :ok = LabProjection.project_position(bid, exit)
    exited = one(Bid)
    assert exited.status == "exited"
    assert exited.exited_at
    refute exited.claimed_at

    assert :ok = LabProjection.project_position(exited, exit)
    replayed_exit = one(Bid)
    assert replayed_exit.exited_at == exited.exited_at

    claim = %{
      "bid_status" => "claimed",
      "exited" => true,
      "claimed" => true
    }

    assert :ok = LabProjection.project_position(replayed_exit, claim)
    claimed = one(Bid)
    assert claimed.status == "claimed"
    assert claimed.claimed_at

    assert :ok = LabProjection.project_position(replayed_exit, exit)
    late_exit = one(Bid)
    assert late_exit.status == "claimed"
    assert late_exit.claimed_at == claimed.claimed_at

    graduated = %{
      "auction_state" => "graduated",
      "subject" => @subject,
      "splitter" => @splitter,
      "receiver" => @receiver,
      "token_symbol" => "DIVERGENT"
    }

    assert :ok = LabProjection.project_position(late_exit, graduated)

    final_bid = one(Bid)
    final_auction = one(Auction)
    final_subject = one(Subject)
    final_launch = one(LaunchJob)
    final_token = one(Token)

    assert final_bid.status == "claimed"
    assert final_bid.exited_at == exited.exited_at
    assert final_auction.state == :graduated
    assert final_subject.splitter_address == @splitter
    assert final_subject.canonical_receiver_address == @receiver
    assert final_launch.status == "complete"
    assert final_launch.step == "graduated"
    assert final_token.auction_id == final_auction.id
    assert final_token.subject_id == final_subject.subject_id
    assert final_token.symbol == "LOCAL"

    finished_at = final_launch.finished_at
    graduated_at = final_token.graduated_at

    assert :ok = LabProjection.project_position(replayed_exit, exit)
    assert one(Bid).status == "claimed"
    assert one(Auction).state == :graduated
    assert one(LaunchJob).status == "complete"

    assert :ok = LabProjection.project_position(final_bid, graduated)
    assert one(LaunchJob).finished_at == finished_at
    assert one(Token).graduated_at == graduated_at
  end

  test "position projection locks the stored bid and auction before joining chain state" do
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())
    auction_id = LabProjection.auction_id(@auction)
    assert :ok = LabProjection.project_bid(bid_operation(auction_id), bid_result())
    [bid] = all(Bid)

    emitted =
      captured(fn ->
        assert :ok =
                 LabProjection.project_position(bid, %{
                   "bid_status" => "exited",
                   "exited" => true,
                   "claimed" => false
                 })
      end)

    assert Enum.any?(selects(emitted, "bids"), &String.contains?(&1, "FOR UPDATE"))
    assert Enum.any?(selects(emitted, "auctions"), &String.contains?(&1, "FOR UPDATE"))
  end

  test "a later invalid resource refuses and rolls the whole launch projection back" do
    operation = put_in(launch_operation(), [:envelope, "arguments", "symbol"], "not-valid")

    assert {:error, _reason} = LabProjection.project_launch(operation, launch_result())
    assert all(Auction) == []
    assert all(Subject) == []
    assert all(LaunchJob) == []
  end

  defp launch_operation(human_account_id \\ nil) do
    %{
      human_account_id: human_account_id || account!("launch-op").id,
      envelope: %{
        "chain_id" => 31_337,
        "expected_signer" => @wallet,
        "metadata" => %{
          "lab" => %{
            "rpc_url" => "http://127.0.0.1:49713",
            "chain_id" => 31_337,
            "addresses" => %{"hook" => @hook}
          }
        },
        "arguments" => %{
          "name" => "Local Regent",
          "symbol" => "LOCAL",
          "description" => "A local fork launch.",
          "website" => "https://example.test/local",
          "image" => "https://example.test/local.png",
          "regent" => @regent,
          "factory" => @factory
        }
      }
    }
  end

  defp launch_result do
    %{
      "launch_id" => "17",
      "subject" => @subject,
      "auction" => @auction,
      "escrow" => @escrow,
      "treasury" => @treasury,
      "start_block" => "100",
      "end_block" => "200"
    }
  end

  defp bid_operation(auction_id) do
    %{
      envelope: %{
        "chain_id" => 31_337,
        "expected_signer" => @wallet,
        "to" => @auction,
        "metadata" => %{
          "lab" => %{
            "rpc_url" => "http://127.0.0.1:49713",
            "chain_id" => 31_337,
            "addresses" => %{"regent" => @regent}
          }
        },
        "arguments" => %{
          "auction_id" => auction_id,
          "amount" => "100",
          "max_price" => "2.5"
        }
      }
    }
  end

  defp bid_result do
    %{
      "onchain_bid_id" => "9",
      "current_clearing_price" => "1"
    }
  end

  defp one(resource) do
    case all(resource) do
      [record] -> record
      records -> flunk("expected one #{inspect(resource)}, got #{length(records)}")
    end
  end

  defp all(resource) do
    action = if resource == Bid, do: :mine, else: :read

    # Projection tests inspect raw stored rows with the trusted System actor.
    resource
    |> Ash.Query.for_read(action, %{}, domain: @domain, actor: @actor, authorize?: false)
    |> then(fn query ->
      if resource == Auction,
        do: Ash.Query.filter(query, not is_nil(auction_address)),
        else: query
    end)
    |> Ash.read!(domain: @domain)
  end

  defp captured(work) do
    parent = self()
    handler = "lab-projection-sql-#{Elixir.System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:autolaunch, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if self() == owner, do: send(owner, {:sql, metadata[:source], metadata.query})
      end,
      parent
    )

    work.()
    :telemetry.detach(handler)
    drained([])
  end

  defp drained(collected) do
    receive do
      {:sql, source, query} -> drained([{source, query} | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp selects(emitted, table) do
    for {^table, query} <- emitted, String.starts_with?(query, "SELECT"), do: query
  end

  defp account!(suffix) do
    nonce = Elixir.System.unique_integer([:positive])
    wallet = "0x" <> String.pad_leading(Integer.to_string(nonce, 16), 40, "0")

    Accounts.register_verified!(
      "did:privy:lab-projection:#{suffix}:#{nonce}",
      wallet,
      [wallet],
      actor: %System{}
    )
  end
end
