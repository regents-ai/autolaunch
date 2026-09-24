defmodule Autolaunch.LabProjectionTest do
  use AutolaunchWeb.ConnCase, async: false

  require Ash.Query

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{System}

  alias Autolaunch.{
    Auction,
    Bid,
    LabProjection,
    LaunchJob,
    Subject
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

  test "a verified local launch and bid project once under exact deterministic identities" do
    assert {:ok, [_ | _]} = LabProjection.project_launch(launch_operation(), launch_result())
    assert {:ok, []} = LabProjection.project_launch(launch_operation(), launch_result())

    [auction] = all(Auction)
    [subject] = all(Subject)
    [launch] = all(LaunchJob)

    assert auction.chain_id == 31_337
    assert auction.state == :created
    assert auction.auction_address == @auction
    assert auction.treasury_address == @treasury
    assert auction.quote_token_address == @regent
    assert auction.required_currency_raised == "500000000000000000000000"

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

  test "a launch row written first keeps its details and state when a second confirmation arrives" do
    creator = account!("first-confirmation")

    assert {:ok, [_ | _]} =
             LabProjection.project_launch(launch_operation(creator.id), launch_result())

    {:ok, _active} =
      Autolaunch.refresh_lab_market_auction(one(Auction), :active, "1.5", %{}, actor: @actor)

    # The launch has moved on since it was written.
    {1, _rows} =
      Autolaunch.Repo.update_all("launch_jobs", set: [status: "complete", step: "graduated"])

    written = one(Auction)

    second =
      account!("second-confirmation").id
      |> launch_operation()
      |> update_in([:envelope, "arguments"], fn arguments ->
        Map.merge(arguments, %{
          "name" => "Other Name",
          "description" => "Other words.",
          "website" => "https://example.test/other",
          "image" => "https://example.test/other.png"
        })
      end)

    assert {:ok, []} = LabProjection.project_launch(second, launch_result())

    assert one(Auction) == written
    assert %{state: :active, current_clearing_price: "1.5"} = written
    assert %{title: "Local Regent", creator_human_account_id: creator_id} = written
    assert creator_id == creator.id
    assert %{agent_name: "Local Regent", status: "complete", step: "graduated"} = one(LaunchJob)
    assert one(Subject).subject_id == LabProjection.subject_identity(@subject)
  end

  test "a launch sends nothing itself and returns its rows' notifications for after commit" do
    Autolaunch.Listings.subscribe()

    assert {:ok, notifications} =
             LabProjection.project_launch(launch_operation(), launch_result())

    refute_received {:autolaunch_listings_changed, _auction_id}

    assert notifications |> Enum.map(& &1.resource) |> Enum.sort() ==
             Enum.sort([Auction, Subject, LaunchJob])
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
          "required_regent_raised_atomic" => "500000000000000000000000",
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
          "auction_address" => @auction,
          "amount" => "100",
          "max_price" => "2.5"
        }
      }
    }
  end

  defp bid_result do
    %{
      "onchain_bid_id" => "9",
      "amount" => "100",
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
