defmodule Autolaunch.LaunchProjectionTest do
  use AutolaunchWeb.ConnCase, async: false

  require Ash.Query

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.{Abi, LaunchAbi}
  alias Autolaunch.Indexer.{Ledger, Log}
  alias Autolaunch.LabProjection
  alias Autolaunch.LaunchOperation
  alias Autolaunch.LaunchProjection

  @actor %System{}
  @wallet "0x2222222222222222222222222222222222222222"
  @auction "0x4444444444444444444444444444444444444444"
  @other_auction "0x9999999999999999999999999999999999999999"
  @treasury "0x6666666666666666666666666666666666666666"
  @factory "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    previous = Application.get_env(:autolaunch, LaunchProjection)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, LaunchProjection, previous),
        else: Application.delete_env(:autolaunch, LaunchProjection)
    end)

    :ok
  end

  test "a recorded LaunchCreated log with a chain_verified operation writes one public auction" do
    account = account!("matched")
    seed_operation!(account, fixture_log().transaction_hash)
    inject_factory!()

    assert :ok = LaunchProjection.project_logs([fixture_log()])

    id = LabProjection.auction_id(@auction)
    assert {:ok, auction} = Autolaunch.get_public_auction(id)
    assert auction.creator_human_account_id == account.id
    assert auction.title == "Base Launch"
    assert auction.summary == "A production launch."
    assert auction.token_symbol == "BASE"
    assert auction.website == "https://example.test/base"
    assert auction.image == "https://example.test/base.png"
    assert auction.auction_address == @auction
    assert auction.treasury_address == @treasury
    assert auction.quote_token_address == Abi.regent_address()
    assert auction.quote_token_symbol == "REGENT"
    assert auction.quote_token_decimals == 18
    assert auction.featured == false
    assert auction.state == :active

    assert {:ok, listed} = Autolaunch.list_auctions()
    assert Enum.any?(listed, &(&1.id == id))
  end

  test "the same log projected twice yields one auction row" do
    account = account!("replay")
    seed_operation!(account, fixture_log().transaction_hash)
    inject_factory!()
    log = fixture_log()

    assert :ok = LaunchProjection.project_logs([log])
    assert :ok = LaunchProjection.project_logs([log])

    id = LabProjection.auction_id(@auction)
    assert {:ok, auction} = Autolaunch.get_public_auction(id)
    assert auction.creator_human_account_id == account.id
    assert {:ok, listed} = Autolaunch.list_auctions()
    assert Enum.count(listed, &(&1.id == id)) == 1
  end

  test "a log whose event auction disagrees with the operation writes nothing" do
    account = account!("mismatch")
    seed_operation!(account, fixture_log().transaction_hash, %{"auction" => @other_auction})
    inject_factory!()

    assert {:error, {:auction_mismatch, @auction, @other_auction}} =
             LaunchProjection.project_logs([fixture_log()])

    assert {:ok, nil} = Autolaunch.get_public_auction(LabProjection.auction_id(@auction))
    assert {:ok, nil} = Autolaunch.get_public_auction(LabProjection.auction_id(@other_auction))
  end

  test "a projection error rolls the committed range back" do
    inject_factory!()
    header_hash = "0x" <> String.duplicate("11", 32)
    parent_hash = "0x" <> String.duplicate("22", 32)
    tx_hash = "0x" <> String.duplicate("33", 32)

    assert {:ok, _source} = Ledger.admit_source(8453, @factory, 10)
    assert {:ok, lease} = Ledger.acquire(8453, 60_000)

    headers = [%{number: 10, hash: header_hash, parent_hash: parent_hash}]

    log = %{
      block_hash: header_hash,
      log_index: 0,
      transaction_hash: tx_hash,
      transaction_index: 0,
      address: @factory,
      topics: [LaunchAbi.selector(:launch_created)],
      data: "0x"
    }

    assert {:error, :undecodable_launch_created} =
             Ledger.commit(lease, {:range, headers, [log], %{number: 10, hash: header_hash}}, 8)

    assert Ledger.canonical_block(8453, 10) == nil

    assert [] =
             Log
             |> Ash.Query.for_read(
               :by_block_hashes,
               %{chain_id: 8453, block_hashes: [header_hash]},
               actor: @actor
             )
             |> Ash.read!()

    assert {:ok, nil} = Autolaunch.get_public_auction(LabProjection.auction_id(@auction))
  end

  test "a LaunchCreated log with no matching operation writes nothing" do
    inject_factory!()

    assert :ok = LaunchProjection.project_logs([fixture_log()])
    assert {:ok, nil} = Autolaunch.get_public_auction(LabProjection.auction_id(@auction))
  end

  test "an address-free manifest returns :ok without a query or a write" do
    account = account!("inert")
    seed_operation!(account, fixture_log().transaction_hash)
    assert LaunchProjection.factory_address() == :none

    queries =
      captured(fn ->
        assert :ok = LaunchProjection.project_logs([fixture_log()])
      end)

    assert queries == []
    assert {:ok, nil} = Autolaunch.get_public_auction(LabProjection.auction_id(@auction))
  end

  test "a Human actor cannot call project_launch" do
    account = account!("human-policy")

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.project_launch_auction(
               LabProjection.auction_attrs(
                 %{
                   "name" => "Nope",
                   "symbol" => "NO",
                   "description" => "Forbidden",
                   "website" => "https://example.test/no",
                   "image" => "https://example.test/no.png"
                 },
                 %{
                   projection_id: LabProjection.auction_id(@auction),
                   creator_human_account_id: account.id,
                   state: :active,
                   auction_address: @auction,
                   quote_token_address: Abi.regent_address(),
                   treasury_address: "0x6666666666666666666666666666666666666666"
                 }
               ),
               actor: %Human{human_account_id: account.id}
             )
  end

  test "the synthetic fixture topic0 is LaunchAbi's LaunchCreated selector" do
    [topic0 | _indexed] = fixture_attrs()["topics"]
    assert topic0 == LaunchAbi.selector(:launch_created)
  end

  defp inject_factory! do
    Application.put_env(:autolaunch, LaunchProjection, factory_address: @factory)
  end

  defp fixture_log do
    attrs = fixture_attrs()

    struct(Log, %{
      chain_id: attrs["chain_id"],
      address: attrs["address"],
      topics: attrs["topics"],
      data: attrs["data"],
      transaction_hash: attrs["transaction_hash"],
      transaction_index: attrs["transaction_index"],
      block_hash: attrs["block_hash"],
      log_index: attrs["log_index"]
    })
  end

  defp fixture_attrs do
    "test/fixtures/launch_events/launch_created.json"
    |> File.read!()
    |> Jason.decode!()
  end

  defp seed_operation!(account, transaction_hash, result \\ %{"auction" => @auction}) do
    actor = %Human{human_account_id: account.id}
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    Ash.Seed.seed!(LaunchOperation, %{
      action_id: String.duplicate("b", 64),
      envelope: %{
        "chain_id" => 8453,
        "arguments" => %{
          "name" => "Base Launch",
          "symbol" => "BASE",
          "description" => "A production launch.",
          "website" => "https://example.test/base",
          "image" => "https://example.test/base.png"
        }
      },
      signer: @wallet,
      step: :launch,
      state: :chain_verified,
      launch_transaction_hash: transaction_hash,
      result: result,
      human_account_id: account.id,
      launch_draft_id: draft.id
    })
  end

  defp account!(suffix) do
    nonce = Elixir.System.unique_integer([:positive])
    wallet = "0x" <> String.pad_leading(Integer.to_string(nonce, 16), 40, "0")

    Accounts.register_verified!(
      "did:privy:launch-projection:#{suffix}:#{nonce}",
      wallet,
      [wallet],
      actor: @actor
    )
  end

  defp captured(work) do
    parent = self()
    handler = "launch-projection-sql-#{Elixir.System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:autolaunch, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if self() == owner, do: send(owner, {:sql, metadata.query})
      end,
      parent
    )

    work.()
    :telemetry.detach(handler)
    drained([])
  end

  defp drained(collected) do
    receive do
      {:sql, query} -> drained([query | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end
end
