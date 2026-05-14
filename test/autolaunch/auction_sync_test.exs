defmodule Autolaunch.AuctionSyncTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.AuctionSync
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.Tokens.RevsplitToken

  defmodule PriceStub do
    def current_token_price_usdc(_chain_id, _pool_id, _token_address), do: {:ok, "0.0123"}
  end

  defmodule GraduatedRpc do
    alias Autolaunch.CCA.Abi

    @q96 79_228_162_514_264_337_593_543_950_336
    @checkpoint_selector Abi.selector(:checkpoint)
    @graduated_selector Abi.selector(:is_graduated)
    @currency_raised_selector Abi.selector(:currency_raised)
    @required_currency_raised_selector Abi.selector(:required_currency_raised)
    @start_block_selector Abi.selector(:start_block)
    @end_block_selector Abi.selector(:end_block)
    @claim_block_selector Abi.selector(:claim_block)

    def block_number(_chain_id, _opts), do: {:ok, 150}
    def rpc_url(_chain_id, _opts), do: {:ok, "http://127.0.0.1:8545"}
    def block_by_number(_chain_id, _block_number, _opts), do: {:ok, nil}
    def code_at(_chain_id, _address, _opts), do: {:ok, "0x01"}
    def tx_receipt(_chain_id, _tx_hash, _opts), do: {:ok, nil}
    def tx_by_hash(_chain_id, _tx_hash, _opts), do: {:ok, nil}
    def get_logs(_chain_id, _filter, _opts), do: {:ok, []}

    def eth_call(_chain_id, _to, @checkpoint_selector, _opts),
      do: {:ok, words([@q96, 0, 0, 0, 0, 0])}

    def eth_call(_chain_id, _to, @graduated_selector, _opts), do: {:ok, word(1)}

    def eth_call(_chain_id, _to, @currency_raised_selector, _opts),
      do: {:ok, word(2_500_000)}

    def eth_call(_chain_id, _to, @required_currency_raised_selector, _opts),
      do: {:ok, word(2_000_000)}

    def eth_call(_chain_id, _to, @start_block_selector, _opts), do: {:ok, word(10)}
    def eth_call(_chain_id, _to, @end_block_selector, _opts), do: {:ok, word(100)}
    def eth_call(_chain_id, _to, @claim_block_selector, _opts), do: {:ok, word(110)}
    def eth_call(_chain_id, _to, _data, _opts), do: {:ok, word(0)}

    defp words(values), do: "0x" <> Enum.map_join(values, "", &word_hex/1)
    defp word(value), do: "0x" <> word_hex(value)
    defp word_hex(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")
  end

  defmodule FailedRpc do
    defdelegate block_number(chain_id, opts), to: GraduatedRpc
    defdelegate rpc_url(chain_id, opts), to: GraduatedRpc
    defdelegate block_by_number(chain_id, block_number, opts), to: GraduatedRpc
    defdelegate code_at(chain_id, address, opts), to: GraduatedRpc
    defdelegate tx_receipt(chain_id, tx_hash, opts), to: GraduatedRpc
    defdelegate tx_by_hash(chain_id, tx_hash, opts), to: GraduatedRpc
    defdelegate get_logs(chain_id, filter, opts), to: GraduatedRpc

    def eth_call(chain_id, to, data, opts) do
      if data == Autolaunch.CCA.Abi.selector(:is_graduated),
        do: {:ok, "0x" <> String.duplicate("0", 64)},
        else: GraduatedRpc.eth_call(chain_id, to, data, opts)
    end
  end

  defmodule CountingRpc do
    def block_number(chain_id, opts) do
      if counter = Application.get_env(:autolaunch, :auction_sync_test_counter) do
        Agent.update(counter, &(&1 + 1))
      end

      GraduatedRpc.block_number(chain_id, opts)
    end

    defdelegate rpc_url(chain_id, opts), to: GraduatedRpc
    defdelegate block_by_number(chain_id, block_number, opts), to: GraduatedRpc
    defdelegate code_at(chain_id, address, opts), to: GraduatedRpc
    defdelegate tx_receipt(chain_id, tx_hash, opts), to: GraduatedRpc
    defdelegate tx_by_hash(chain_id, tx_hash, opts), to: GraduatedRpc
    defdelegate get_logs(chain_id, filter, opts), to: GraduatedRpc
    defdelegate eth_call(chain_id, to, data, opts), to: GraduatedRpc
  end

  setup do
    previous_rpc = Application.get_env(:autolaunch, :cca_rpc_adapter)
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_sync = Application.get_env(:autolaunch, :auction_sync, [])

    {:ok, _count} = Cachex.clear(:autolaunch_cache)

    Application.put_env(
      :autolaunch,
      :auction_sync,
      Keyword.put(previous_sync, :snapshot_ttl_seconds, 60)
    )

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.put(previous_launch, :token_pricing_module, PriceStub)
    )

    on_exit(fn ->
      if previous_rpc do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_rpc)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end

      Application.put_env(:autolaunch, :launch, previous_launch)
      Application.put_env(:autolaunch, :auction_sync, previous_sync)
      Application.delete_env(:autolaunch, :auction_sync_test_counter)
    end)

    :ok
  end

  test "graduated auctions update auction state and create one Revsplit token" do
    Application.put_env(:autolaunch, :cca_rpc_adapter, GraduatedRpc)

    auction =
      insert_auction("graduated", token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    insert_job("job_graduated", "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    assert {:ok, %{token?: true, failed?: false}} = AuctionSync.sync_auction(auction)
    synced = Repo.get!(Auction, auction.id)

    assert synced.chain_state == "graduated"
    assert synced.onchain_graduated
    assert synced.onchain_currency_raised_raw == "2500000"

    assert [token] = Repo.all(RevsplitToken)
    assert token.token_address == "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    assert token.auction_raise_usdc == "2.5"
    assert token.fdv_usdc == "1230000000"

    assert {:ok, %{token?: false}} = AuctionSync.sync_auction(Repo.get!(Auction, auction.id))
    assert Repo.aggregate(RevsplitToken, :count) == 1
  end

  test "auction snapshots are cached across immediate syncs" do
    counter = start_supervised!({Agent, fn -> 0 end})

    Application.put_env(:autolaunch, :auction_sync_test_counter, counter)
    Application.put_env(:autolaunch, :cca_rpc_adapter, CountingRpc)

    auction =
      insert_auction("cached", token_address: "0xdddddddddddddddddddddddddddddddddddddddd")

    insert_job("job_cached", "0xdddddddddddddddddddddddddddddddddddddddd")

    assert {:ok, %{token?: true}} = AuctionSync.sync_auction(auction)
    assert {:ok, %{token?: false}} = AuctionSync.sync_auction(Repo.get!(Auction, auction.id))

    assert Agent.get(counter, & &1) == 1
  end

  test "failed auctions update state without creating a Revsplit token" do
    Application.put_env(:autolaunch, :cca_rpc_adapter, FailedRpc)

    auction =
      insert_auction("failed", token_address: "0xcccccccccccccccccccccccccccccccccccccccc")

    insert_job("job_failed", "0xcccccccccccccccccccccccccccccccccccccccc")

    assert {:ok, %{token?: false, failed?: true}} = AuctionSync.sync_auction(auction)
    synced = Repo.get!(Auction, auction.id)

    assert synced.chain_state == "failed_minimum"
    refute synced.onchain_graduated
    assert Repo.aggregate(RevsplitToken, :count) == 0
  end

  test "sync candidates keep open auctions and skip already synced terminal auctions" do
    open =
      insert_auction("open_candidate",
        token_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )

    completed =
      insert_auction("completed_candidate",
        token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      )

    unsynced_terminal =
      insert_auction("unsynced_terminal_candidate",
        token_address: "0xcccccccccccccccccccccccccccccccccccccccc"
      )

    now = DateTime.utc_now()

    completed
    |> Auction.changeset(%{
      chain_state: "graduated",
      onchain_synced_at: now,
      onchain_graduated: true
    })
    |> Repo.update!()

    unsynced_terminal
    |> Auction.changeset(%{chain_state: "failed_minimum"})
    |> Repo.update!()

    source_ids =
      AuctionSync.sync_candidates(chain_id: 8_453, limit: 10)
      |> Enum.map(& &1.source_job_id)

    assert open.source_job_id in source_ids
    assert unsynced_terminal.source_job_id in source_ids
    refute completed.source_job_id in source_ids
  end

  defp insert_auction(suffix, attrs) do
    now = DateTime.utc_now()
    job_id = "auc_" <> suffix

    Repo.insert!(
      Auction.changeset(%Auction{}, %{
        source_job_id: job_id,
        agent_id: "8453:#{suffix}",
        agent_name: "Agent #{suffix}",
        owner_address: "0x1111111111111111111111111111111111111111",
        auction_address: address_for_suffix(suffix),
        token_address: Keyword.fetch!(attrs, :token_address),
        network: "base-mainnet",
        chain_id: 8_453,
        status: "active",
        started_at: DateTime.add(now, -10_000, :second),
        ends_at: DateTime.add(now, -2_000, :second),
        minimum_raise_usdc: "2",
        minimum_raise_usdc_raw: "2000000"
      })
    )
  end

  defp insert_job(job_id, token_address) do
    now = DateTime.utc_now()

    job =
      Repo.insert!(
        Job.create_changeset(%Job{}, %{
          job_id: job_id,
          owner_address: "0x1111111111111111111111111111111111111111",
          agent_id: "8453:#{job_id}",
          agent_name: "Agent #{job_id}",
          token_name: "Agent Token",
          token_symbol: "AGT",
          agent_safe_address: "0x1111111111111111111111111111111111111111",
          network: "base-mainnet",
          chain_id: 8_453,
          status: "ready",
          step: "ready",
          total_supply: "1000",
          message: "signed",
          siwa_nonce: "nonce-#{job_id}",
          siwa_signature: "sig",
          issued_at: now
        })
      )

    job
    |> Job.update_changeset(%{
      token_address: token_address,
      subject_id: "0x" <> String.duplicate("1", 64),
      revenue_share_splitter_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      pool_id: "0x" <> String.duplicate("2", 64)
    })
    |> Repo.update!()
  end

  defp address_for_suffix(suffix) do
    "0x" <> (:crypto.hash(:sha256, suffix) |> Base.encode16(case: :lower) |> String.slice(0, 40))
  end
end
