defmodule Autolaunch.MarketTrackingTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Abi
  alias Autolaunch.Launch
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.Bid
  alias Autolaunch.Repo

  @auction_address "0x0000000000000000000000000000000000000011"
  @owner_address "0x00000000000000000000000000000000000000aa"

  setup do
    previous_adapter = Application.get_env(:autolaunch, :cca_rpc_adapter)
    Application.put_env(:autolaunch, :cca_rpc_adapter, __MODULE__.FakeRpc)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_adapter)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end
    end)

    human =
      %HumanUser{}
      |> HumanUser.changeset(%{
        privy_user_id: "did:privy:test",
        wallet_address: @owner_address,
        display_name: "Operator"
      })
      |> Repo.insert!()

    auction =
      %Auction{}
      |> Auction.changeset(%{
        source_job_id: "auc_live",
        agent_id: "1:1337",
        agent_name: "Regent Researcher",
        owner_address: @owner_address,
        auction_address: @auction_address,
        token_address: "0x0000000000000000000000000000000000000022",
        network: "ethereum-mainnet",
        chain_id: 1,
        status: "active",
        started_at: DateTime.utc_now(),
        ends_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
        claim_at: DateTime.add(DateTime.utc_now(), 172_800, :second),
        bidders: 1,
        raised_currency: "2.0 USDC",
        target_currency: "10 USDC",
        progress_percent: 20
      })
      |> Repo.insert!()

    %{human: human, auction: auction}
  end

  test "place_bid registers a confirmed onchain bid receipt", %{human: human, auction: auction} do
    Process.put(:fake_rpc_scenario, :register_bid)

    assert {:ok, position} =
             Launch.place_bid(
               auction.source_job_id,
               %{
                 "tx_hash" => tx_hash("11"),
                 "amount" => "2.0",
                 "max_price" => "3.0",
                 "current_clearing_price" => "2.0",
                 "estimated_tokens_if_end_now" => "0",
                 "estimated_tokens_if_no_other_bids_change" => "0.666667",
                 "inactive_above_price" => "3.0",
                 "status_band" => "active"
               },
               human
             )

    assert position.onchain_bid_id == "7"
    assert position.status == "active"
    assert position.tx_actions.exit == nil

    tracked = Repo.get!(Bid, "auc_live:7")
    assert tracked.submit_tx_hash == tx_hash("11")
    assert tracked.onchain_bid_id == "7"
  end

  test "list_positions exposes claim action once the exited bid is claimable", %{
    human: human,
    auction: auction
  } do
    Process.put(:fake_rpc_scenario, :claimable_bid)

    %Bid{}
    |> Bid.create_changeset(%{
      bid_id: "auc_live:9",
      privy_user_id: human.privy_user_id,
      owner_address: @owner_address,
      auction_id: auction.source_job_id,
      auction_address: auction.auction_address,
      chain_id: auction.chain_id,
      agent_id: auction.agent_id,
      agent_name: auction.agent_name,
      network: auction.network,
      onchain_bid_id: "9",
      amount: Decimal.new("1.5"),
      max_price: Decimal.new("3.0"),
      current_clearing_price: Decimal.new("2.0"),
      current_status: "claimable"
    })
    |> Repo.insert!()

    [position] = Launch.list_positions(human)

    assert position.status == "claimable"
    assert position.tx_actions.claim.tx_request.to == @auction_address
    assert position.tokens_filled == "12"
  end

  test "list_positions exposes partial exit action with checkpoint hints", %{
    human: human,
    auction: auction
  } do
    Process.put(:fake_rpc_scenario, :inactive_bid)

    %Bid{}
    |> Bid.create_changeset(%{
      bid_id: "auc_live:12",
      privy_user_id: human.privy_user_id,
      owner_address: @owner_address,
      auction_id: auction.source_job_id,
      auction_address: auction.auction_address,
      chain_id: auction.chain_id,
      agent_id: auction.agent_id,
      agent_name: auction.agent_name,
      network: auction.network,
      onchain_bid_id: "12",
      amount: Decimal.new("2.0"),
      max_price: Decimal.new("3.0"),
      current_clearing_price: Decimal.new("2.0"),
      current_status: "inactive"
    })
    |> Repo.insert!()

    [position] = Launch.list_positions(human)

    assert position.status == "inactive"
    assert position.tx_actions.exit.type == :exit_partially_filled_bid
    assert position.tx_actions.exit.last_fully_filled_checkpoint_block == 150
    assert position.tx_actions.exit.outbid_block == 170
  end

  defmodule FakeRpc do
    alias Autolaunch.CCA.Abi

    @q96 79_228_162_514_264_337_593_543_950_336
    @auction_address "0x0000000000000000000000000000000000000011"
    @owner_address "0x00000000000000000000000000000000000000aa"

    def block_number(1) do
      {:ok, scenario() |> scenario_data() |> Map.fetch!(:block_number)}
    end

    def eth_call(1, @auction_address, data) do
      selector = String.slice(data, 0, 10)
      config = scenario() |> scenario_data()

      cond do
        selector == Abi.selector(:checkpoint) ->
          {:ok,
           encode_words([
             config.checkpoint.clearing_price_q96,
             0,
             config.checkpoint.cumulative_mps_per_price,
             config.checkpoint.cumulative_mps,
             0,
             0
           ])}

        selector == Abi.selector(:floor_price) ->
          {:ok, encode_words([config.floor_price_q96])}

        selector == Abi.selector(:tick_spacing) ->
          {:ok, encode_words([config.tick_spacing_q96])}

        selector == Abi.selector(:next_active_tick_price) ->
          {:ok, encode_words([Abi.max_u256()])}

        selector == Abi.selector(:sum_currency_demand_above_clearing_q96) ->
          {:ok, encode_words([config.sum_currency_demand_above_clearing_q96])}

        selector == Abi.selector(:total_supply) ->
          {:ok, encode_words([config.total_supply])}

        selector == Abi.selector(:currency_raised) ->
          {:ok, encode_words([config.currency_raised_wei])}

        selector == Abi.selector(:total_cleared) ->
          {:ok, encode_words([config.total_cleared_units])}

        selector == Abi.selector(:start_block) ->
          {:ok, encode_words([100])}

        selector == Abi.selector(:end_block) ->
          {:ok, encode_words([200])}

        selector == Abi.selector(:claim_block) ->
          {:ok, encode_words([210])}

        selector == Abi.selector(:max_bid_price) ->
          {:ok, encode_words([10 * @q96])}

        selector == Abi.selector(:is_graduated) ->
          {:ok, encode_words([if(config.is_graduated, do: 1, else: 0)])}

        selector == Abi.selector(:bids) ->
          bid_id = decode_uint_arg(data)
          bid = Map.fetch!(config.bids, bid_id)

          {:ok,
           encode_words([
             bid.start_block,
             bid.start_cumulative_mps,
             bid.exited_block,
             bid.max_price_q96,
             String.to_integer(String.slice(bid.owner_address, 2..-1//1), 16),
             bid.amount_q96,
             bid.tokens_filled_units
           ])}

        true ->
          {:error, :unsupported_call}
      end
    end

    def tx_receipt(1, tx_hash) do
      {:ok,
       scenario()
       |> scenario_data()
       |> Map.get(:receipts, %{})
       |> Map.get(String.downcase(tx_hash))}
    end

    def get_logs(1, _filter) do
      {:ok, scenario() |> scenario_data() |> Map.get(:checkpoint_logs, [])}
    end

    defp scenario do
      Process.get(:fake_rpc_scenario, :register_bid)
    end

    defp scenario_data(:register_bid) do
      %{
        block_number: 150,
        checkpoint: %{
          clearing_price_q96: 2 * @q96,
          cumulative_mps: 2_000_000,
          cumulative_mps_per_price: 0
        },
        floor_price_q96: @q96,
        tick_spacing_q96: @q96,
        sum_currency_demand_above_clearing_q96: 0,
        total_supply: 1_000_000_000_000_000_000,
        currency_raised_wei: 2_000_000_000_000_000_000,
        total_cleared_units: 1_000_000_000_000_000_000,
        is_graduated: true,
        bids: %{
          7 => %{
            start_block: 150,
            start_cumulative_mps: 2_000_000,
            exited_block: 0,
            max_price_q96: 3 * @q96,
            owner_address: @owner_address,
            amount_q96: 2_000_000_000_000_000_000 * @q96,
            tokens_filled_units: 0
          }
        },
        checkpoint_logs: [
          checkpoint_log(150, 2 * @q96, 2_000_000)
        ],
        receipts: %{
          tx_hash("11") => %{
            transaction_hash: tx_hash("11"),
            status: 1,
            block_number: 150,
            from: @owner_address,
            to: @auction_address,
            logs: [
              %{
                address: @auction_address,
                topics: [
                  Abi.event_topic(:bid_submitted),
                  topic_word(7),
                  topic_word(@owner_address)
                ],
                data: encode_words([3 * @q96, 2_000_000_000_000_000_000]),
                block_number: 150,
                transaction_hash: tx_hash("11"),
                log_index: 0
              }
            ]
          }
        }
      }
    end

    defp scenario_data(:claimable_bid) do
      %{
        block_number: 220,
        checkpoint: %{
          clearing_price_q96: 2 * @q96,
          cumulative_mps: 8_000_000,
          cumulative_mps_per_price: 0
        },
        floor_price_q96: @q96,
        tick_spacing_q96: @q96,
        sum_currency_demand_above_clearing_q96: 0,
        total_supply: 1_000_000_000_000_000_000,
        currency_raised_wei: 5_000_000_000_000_000_000,
        total_cleared_units: 12_000_000_000_000_000_000,
        is_graduated: true,
        bids: %{
          9 => %{
            start_block: 150,
            start_cumulative_mps: 2_000_000,
            exited_block: 205,
            max_price_q96: 3 * @q96,
            owner_address: @owner_address,
            amount_q96: 1_500_000_000_000_000_000 * @q96,
            tokens_filled_units: 12_000_000_000_000_000_000
          }
        },
        checkpoint_logs: [
          checkpoint_log(150, 2 * @q96, 2_000_000),
          checkpoint_log(200, 2 * @q96, 8_000_000)
        ]
      }
    end

    defp scenario_data(:inactive_bid) do
      %{
        block_number: 180,
        checkpoint: %{
          clearing_price_q96: 4 * @q96,
          cumulative_mps: 5_000_000,
          cumulative_mps_per_price: 0
        },
        floor_price_q96: @q96,
        tick_spacing_q96: @q96,
        sum_currency_demand_above_clearing_q96: 0,
        total_supply: 1_000_000_000_000_000_000,
        currency_raised_wei: 4_000_000_000_000_000_000,
        total_cleared_units: 4_000_000_000_000_000_000,
        is_graduated: true,
        bids: %{
          12 => %{
            start_block: 150,
            start_cumulative_mps: 2_000_000,
            exited_block: 0,
            max_price_q96: 3 * @q96,
            owner_address: @owner_address,
            amount_q96: 2_000_000_000_000_000_000 * @q96,
            tokens_filled_units: 2_000_000_000_000_000_000
          }
        },
        checkpoint_logs: [
          checkpoint_log(150, 2 * @q96, 2_000_000),
          checkpoint_log(160, 3 * @q96, 3_000_000),
          checkpoint_log(170, 4 * @q96, 4_000_000)
        ]
      }
    end

    defp encode_words(words) do
      "0x" <>
        Enum.map_join(words, "", &(Integer.to_string(&1, 16) |> String.pad_leading(64, "0")))
    end

    defp decode_uint_arg(data) do
      data |> String.slice(10, 64) |> String.to_integer(16)
    end

    defp checkpoint_log(block_number, clearing_price_q96, cumulative_mps) do
      %{
        address: @auction_address,
        topics: [Abi.event_topic(:checkpoint_updated)],
        data: encode_words([block_number, clearing_price_q96, cumulative_mps]),
        block_number: block_number,
        transaction_hash: tx_hash(Integer.to_string(block_number)),
        log_index: 0
      }
    end

    defp topic_word("0x" <> address) when byte_size(address) == 40 do
      "0x" <> String.pad_leading(String.downcase(address), 64, "0")
    end

    defp topic_word(value) when is_integer(value) do
      "0x" <> (value |> Integer.to_string(16) |> String.pad_leading(64, "0"))
    end

    defp tx_hash(seed) do
      "0x" <> String.pad_leading(seed, 64, "1")
    end
  end

  defp tx_hash(seed), do: "0x" <> String.pad_leading(seed, 64, "1")
end
