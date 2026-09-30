defmodule Autolaunch.Chain.LaunchAbi do
  @moduledoc """
  The Revstake launch terms and the `LaunchCreated` decoder for the Base launch
  factory.

  Every signature here is declared by an ABI file taken from the contract
  source, and the module refuses to compile unless that file still declares it.
  Calldata is encoded from the deployment description (`Autolaunch.LabAbi`),
  never here.
  """

  alias Autolaunch.Chain.Abi

  @factory_abi_path Path.expand(
                      "../../../contracts/abi/regents-autolaunch-factory-v2.json",
                      __DIR__
                    )
  @strategy_abi_path Path.expand("../../../contracts/abi/regent-lbp-strategy-v2.json", __DIR__)
  @external_resource @factory_abi_path
  @external_resource @strategy_abi_path

  @uint128_max Integer.pow(2, 128) - 1

  # Every Revstake auction opens at 0.000001 REGENT per token: that price in Q96,
  # rounded down to the strategy's 100-tick grid. Launchers choose no floor and
  # no minimum raise of their own.
  @floor_price_q96 79_228_162_514_264_337_593_500

  @factory_events %{
    launch_created:
      {"LaunchCreated(uint256,address,address,address,address,address,uint256,uint128,uint64,uint64)",
       "0x03b8e7e24c72d48c2e84e289badf2b06c6110f781ed91973fbee4f42b14d5d12"}
  }

  # The launch terms, read for display and never chosen, plus the three strategy
  # identities a review compares a treasury against. The bid tick and the
  # required raise are the strategy's own answers for the fixed floor.
  @strategy_functions %{
    factory: {"factory()", "0xc45a0155"},
    hook: {"hook()", "0x7f5a7c7b"},
    lp_locker: {"lpLocker()", "0x03fc2013"},
    start_delay_blocks: {"START_DELAY_BLOCKS()", "0x48bd92bb"},
    auction_duration_blocks: {"AUCTION_DURATION_BLOCKS()", "0x56586874"},
    claim_delay_blocks: {"CLAIM_DELAY_BLOCKS()", "0x4a9923ac"},
    migration_delay_blocks: {"MIGRATION_DELAY_BLOCKS()", "0xbfd822e1"},
    auction_allocation: {"AUCTION_ALLOCATION()", "0x80ff9c38"},
    reserve_allocation: {"RESERVE_ALLOCATION()", "0x7b5c7f03"},
    pending_allocation: {"PENDING_ALLOCATION()", "0xebd6c243"},
    pool_fee: {"POOL_FEE()", "0xdd1b9c4a"},
    pool_tick_spacing: {"POOL_TICK_SPACING()", "0x7381527f"},
    bid_tick_q96: {"bidTickSpacingFor(uint256)", "0x9e82ecfc"},
    required_regent_raised: {"requiredRegentRaisedFor(uint256,uint128)", "0x711d8db3"}
  }

  # The launch terms in the order a review presents them: the strategy reads
  # other than the identity reads, plus the fixed floor.
  @terms [
    :start_delay_blocks,
    :auction_duration_blocks,
    :claim_delay_blocks,
    :migration_delay_blocks,
    :auction_allocation,
    :reserve_allocation,
    :pending_allocation,
    :floor_price_q96,
    :bid_tick_q96,
    :required_regent_raised,
    :pool_fee,
    :pool_tick_spacing
  ]

  Enum.sort(@terms -- [:floor_price_q96]) ==
    Enum.sort(Map.keys(@strategy_functions) -- [:factory, :hook, :lp_locker]) ||
    raise "the launch terms drifted from the declared strategy reads"

  # A selector or topic is only evidence if the derived ABI really declares the
  # signature it came from. The check runs inline, against the decoded file
  # alone, so proving it adds no compile-time dependency of its own.
  for {path, functions, events} <- [
        {@factory_abi_path, %{}, @factory_events},
        {@strategy_abi_path, @strategy_functions, %{}}
      ] do
    abi = path |> File.read!() |> Jason.decode!()

    for {kind, entries} <- [{"function", functions}, {"event", events}],
        {_id, {signature, _selector}} <- entries do
      declared? =
        Enum.any?(abi, fn
          %{"type" => ^kind, "name" => name, "inputs" => inputs} ->
            "#{name}(#{Enum.map_join(inputs, ",", & &1["type"])})" == signature

          _entry ->
            false
        end)

      declared? || raise "launch ABI #{Path.basename(path)} is missing #{signature}"
    end
  end

  @doc "The exact selector of one admitted read, or the `topic0` of one admitted event."
  @spec selector(atom()) :: String.t()
  def selector(id), do: id |> entry() |> elem(1)

  @doc "The launch terms a review reads, in the order it presents them."
  @spec terms() :: [atom()]
  def terms, do: @terms

  @doc "Every Revstake auction's floor price, in Q96."
  @spec floor_price_q96() :: pos_integer()
  def floor_price_q96, do: @floor_price_q96

  @doc "The strategy read behind one launch term."
  @spec term_signature(atom()) :: String.t()
  def term_signature(id), do: @strategy_functions |> Map.fetch!(id) |> elem(0)

  # Events

  @doc """
  The one `LaunchCreated` this factory emitted, or `:error`.

  Absent, duplicated, malformed and foreign-emitter are all `:error`: a launch is
  proved by exactly one event from exactly the reviewed factory.
  """
  @spec launch_created([map()], String.t()) :: {:ok, map()} | :error
  def launch_created(logs, factory) do
    with {:ok, {[launch_id, launcher_word, subject_word], data}} <-
           Abi.one_event(logs, selector(:launch_created), factory, 3, 7),
         [auction, escrow, treasury, floor_price_q96, required_raise, start_block, end_block] <-
           data,
         {:ok, launcher} <- Abi.word_address(launcher_word),
         {:ok, subject} <- Abi.word_address(subject_word),
         {:ok, auction} <- Abi.word_address(auction),
         {:ok, escrow} <- Abi.word_address(escrow),
         {:ok, treasury} <- Abi.word_address(treasury),
         true <- required_raise <= @uint128_max and launch_id > 0 do
      {:ok,
       %{
         launch_id: launch_id,
         launcher: launcher,
         subject: subject,
         auction: auction,
         escrow: escrow,
         treasury: treasury,
         floor_price_q96: floor_price_q96,
         required_regent_raised: required_raise,
         start_block: start_block,
         end_block: end_block
       }}
    else
      _contradiction -> :error
    end
  end

  @entries Map.merge(@factory_events, @strategy_functions)

  defp entry(id), do: Map.fetch!(@entries, id)
end
