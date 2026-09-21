defmodule Autolaunch.Chain.LaunchAbi do
  @moduledoc """
  The frozen launch terms and the `LaunchCreated` decoder for the Base launch
  factory.

  Every signature here is declared by an ABI file derived from the exact
  integrated contract source, and the module refuses to compile unless that file
  still declares it. Calldata is encoded from the deployment description
  (`Autolaunch.LabAbi`), never here.
  """

  alias Autolaunch.Chain.Abi

  @factory_abi_path Path.expand(
                      "../../../contracts/abi/regents-autolaunch-factory-v1.json",
                      __DIR__
                    )
  @strategy_abi_path Path.expand("../../../contracts/abi/regent-lbp-strategy-v1.json", __DIR__)
  @external_resource @factory_abi_path
  @external_resource @strategy_abi_path

  @uint128_max Integer.pow(2, 128) - 1

  # REGENT is an 18-decimal token, so a human decimal raise scales by exactly this.
  @regent_decimals 18
  @raise_syntax ~r/\A(\d+)(?:\.(\d{1,#{@regent_decimals}}))?\z/

  @factory_events %{
    launch_created:
      {"LaunchCreated(uint256,address,address,address,address,address,uint128,uint64,uint64)",
       "0x7b5b327fb976e7bf5fb279515b3ea1821166f52c0b46e5825f0146b249f963f2"}
  }

  # The founder-frozen launch terms, read for display and never chosen, plus the
  # two strategy identities a review compares a treasury against.
  @strategy_functions %{
    factory: {"factory()", "0xc45a0155"},
    hook: {"hook()", "0x7f5a7c7b"},
    start_delay_blocks: {"START_DELAY_BLOCKS()", "0x48bd92bb"},
    auction_duration_blocks: {"AUCTION_DURATION_BLOCKS()", "0x56586874"},
    claim_delay_blocks: {"CLAIM_DELAY_BLOCKS()", "0x4a9923ac"},
    migration_delay_blocks: {"MIGRATION_DELAY_BLOCKS()", "0xbfd822e1"},
    floor_price_q96: {"FLOOR_PRICE_Q96()", "0x14ec99b0"},
    bid_tick_q96: {"BID_TICK_Q96()", "0xf276cd78"},
    auction_allocation: {"AUCTION_ALLOCATION()", "0x80ff9c38"},
    reserve_allocation: {"RESERVE_ALLOCATION()", "0x7b5c7f03"},
    pending_allocation: {"PENDING_ALLOCATION()", "0xebd6c243"},
    pool_fee: {"POOL_FEE()", "0xdd1b9c4a"},
    pool_tick_spacing: {"POOL_TICK_SPACING()", "0x7381527f"},
    max_reachable_raise: {"MAX_REACHABLE_RAISE()", "0x8b8e722e"}
  }

  # The frozen terms in the order a review presents them, which has to stay
  # exactly the strategy reads other than the two identity reads.
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
    :pool_fee,
    :pool_tick_spacing,
    :max_reachable_raise
  ]

  Enum.sort(@terms) == Enum.sort(Map.keys(@strategy_functions) -- [:factory, :hook]) ||
    raise "the frozen launch terms drifted from the declared strategy reads"

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

      declared? || raise "derived C4 ABI #{Path.basename(path)} is missing #{signature}"
    end
  end

  @doc "The exact selector of one admitted read, or the `topic0` of one admitted event."
  @spec selector(atom()) :: String.t()
  def selector(id), do: id |> entry() |> elem(1)

  @doc "The founder-frozen strategy terms a review reads, in the order it presents them."
  @spec terms() :: [atom()]
  def terms, do: @terms

  # Events

  @doc """
  The one `LaunchCreated` this factory emitted, or `:error`.

  Absent, duplicated, malformed and foreign-emitter are all `:error`: a launch is
  proved by exactly one event from exactly the reviewed factory.
  """
  @spec launch_created([map()], String.t()) :: {:ok, map()} | :error
  def launch_created(logs, factory) do
    with {:ok, {[launch_id, launcher_word, subject_word], data}} <-
           Abi.one_event(logs, selector(:launch_created), factory, 3, 6),
         [auction, escrow, treasury, required_raise, start_block, end_block] <- data,
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
         required_regent_raised: required_raise,
         start_block: start_block,
         end_block: end_block
       }}
    else
      _contradiction -> :error
    end
  end

  # Amounts

  @doc """
  The 18-decimal atomic REGENT a human decimal names, exactly.

  This is string arithmetic on purpose. The raise is compared against a 36-digit
  strategy maximum, which `Decimal`'s default 28-digit context cannot represent
  without rounding, so the fractional part is padded to eighteen digits and the
  whole thing is parsed as one integer. Excess precision, a sign, an exponent and
  anything else that is not a plain decimal are refused rather than rounded.
  """
  @spec atomic_raise(term()) :: {:ok, pos_integer()} | :error
  def atomic_raise(value) when is_binary(value) do
    case Regex.run(@raise_syntax, value, capture: :all_but_first) do
      [whole] -> scaled(whole, "")
      [whole, fraction] -> scaled(whole, fraction)
      nil -> :error
    end
  end

  def atomic_raise(_value), do: :error

  defp scaled(whole, fraction) do
    case String.to_integer(whole <> String.pad_trailing(fraction, @regent_decimals, "0")) do
      0 -> :error
      atomic -> {:ok, atomic}
    end
  end

  @doc "The largest raise the `uint128` field can carry."
  @spec uint128_max() :: pos_integer()
  def uint128_max, do: @uint128_max

  @entries Map.merge(@factory_events, @strategy_functions)

  defp entry(id), do: Map.fetch!(@entries, id)
end
