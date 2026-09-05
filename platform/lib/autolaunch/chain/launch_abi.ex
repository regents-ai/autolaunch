defmodule Autolaunch.Chain.LaunchAbi do
  @moduledoc """
  The one encoder and decoder for the direct-wallet launch lane.

  Every signature here is declared by an ABI file derived from the exact
  integrated contract source, and the module refuses to compile unless that file
  still declares it. `launch` is the only dynamic call this product has: one
  tuple of five strings and three static fields, encoded here and nowhere else.

  The browser receives already-reviewed bytes, so nothing outside this module
  ever builds calldata.
  """

  alias Autolaunch.Chain.{Abi, Address}

  @factory_abi_path Path.expand(
                      "../../../contracts/abi/regents-autolaunch-factory-v1.json",
                      __DIR__
                    )
  @strategy_abi_path Path.expand("../../../contracts/abi/regent-lbp-strategy-v1.json", __DIR__)
  @external_resource @factory_abi_path
  @external_resource @strategy_abi_path

  @word 32
  @uint128_max Integer.pow(2, 128) - 1
  @uint256_max Integer.pow(2, 256) - 1
  @int24_bound Integer.pow(2, 23)
  @sign_bit Integer.pow(2, 255)
  @two_pow_256 Integer.pow(2, 256)

  # REGENT is an 18-decimal token, so a human decimal raise scales by exactly this.
  @regent_decimals 18
  @raise_syntax ~r/\A(\d+)(?:\.(\d{1,#{@regent_decimals}}))?\z/

  # The one signature this lane may ever spend, written out in full. It is the
  # literal the selector below is derived from, and the manifest test proves it
  # against the derived ABI's own canonicalization and against Foundry.
  @launch_signature "launch((string,string,string,string,string,address,uint128,uint256))"

  # The exact tuple `launch` takes, in the exact order the factory declares it.
  # This list is deliberately a separate statement of the same contract: it says
  # what the derived ABI file must declare and what the head of an encoding is,
  # and the signature above is never rebuilt from it. A drift between the two
  # shows up as calldata that disagrees with `cast calldata`.
  @launch_components ~w(string string string string string address uint128 uint256)
  @launch_head length(@launch_components) * @word

  @factory_functions %{
    launch: {@launch_signature, "0xd0464e3e"},
    launch_fee: {"launchFee()", "0xcf3cf573"},
    launches_paused: {"launchesPaused()", "0x3bc340c2"},
    strategy: {"strategy()", "0xa8c62e76"},
    launches: {"launches(uint256)", "0x7b443a76"},
    launch_id_of_subject: {"launchIdOfSubject(address)", "0xca2afc6c"}
  }

  @factory_events %{
    launch_created:
      {"LaunchCreated(uint256,address,address,address,address,address,uint128,uint64,uint64)",
       "0x7b5b327fb976e7bf5fb279515b3ea1821166f52c0b46e5825f0146b249f963f2"},
    launch_fee_collected:
      {"LaunchFeeCollected(uint256,address,address,uint256)",
       "0x9f3b0730114747603d4395bfe87ba93159db303d7898a3a197877eb01a64b9c6"}
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
  # alone, so proving it adds no compile-time dependency of its own. Every entry
  # but `launch` has flat argument types; `launch` is matched against the exact
  # component list its literal signature above is built from, so this stays a
  # declaration check rather than a second signature canonicalizer.
  for {path, functions, events} <- [
        {@factory_abi_path, @factory_functions, @factory_events},
        {@strategy_abi_path, @strategy_functions, %{}}
      ] do
    abi = path |> File.read!() |> Jason.decode!()

    for {kind, entries} <- [{"function", functions}, {"event", events}],
        {_id, {signature, _selector}} <- entries do
      declared? =
        Enum.any?(abi, fn
          %{
            "type" => "function",
            "name" => "launch",
            "inputs" => [%{"type" => "tuple", "components" => components}]
          } ->
            signature == @launch_signature and
              Enum.map(components, & &1["type"]) == @launch_components

          %{"type" => ^kind, "name" => name, "inputs" => inputs} ->
            "#{name}(#{Enum.map_join(inputs, ",", & &1["type"])})" == signature

          _entry ->
            false
        end)

      declared? || raise "derived C4 ABI #{Path.basename(path)} is missing #{signature}"
    end
  end

  @doc "The exact declared signature of one admitted call, read, or event."
  @spec signature(atom()) :: String.t()
  def signature(id), do: id |> entry() |> elem(0)

  @doc "The exact selector of one admitted call or read, or the `topic0` of one admitted event."
  @spec selector(atom()) :: String.t()
  def selector(id), do: id |> entry() |> elem(1)

  @doc "The founder-frozen strategy terms a review reads, in the order it presents them."
  @spec terms() :: [atom()]
  def terms, do: @terms

  # The one customer call

  @doc """
  The exact `launch` calldata for one reviewed draft.

  One dynamic tuple: a head word pointing at it, eight tuple head words, then the
  five string tails in declaration order. Every string is spent as the exact
  UTF-8 bytes the draft holds; there is no normalization anywhere in this lane.
  """
  @spec encode_launch(map()) :: String.t()
  def encode_launch(%{
        name: name,
        symbol: symbol,
        description: description,
        website: website,
        image: image,
        treasury: treasury,
        required_regent_raised: raise_atomic,
        expected_launch_fee: fee
      }) do
    tails = Enum.map([name, symbol, description, website, image], &string_tail!/1)

    {offsets, _end} =
      Enum.map_reduce(tails, @launch_head, fn tail, offset ->
        {uint!(offset, @uint256_max), offset + div(byte_size(tail), 2)}
      end)

    selector(:launch) <>
      uint!(@word, @uint256_max) <>
      Enum.join(offsets) <>
      address!(treasury) <>
      uint!(raise_atomic, @uint128_max) <>
      uint!(fee, @uint256_max) <>
      Enum.join(tails)
  end

  # Reads

  @spec encode_read(atom()) :: String.t()
  def encode_read(id), do: selector(id)

  @spec encode_launches(non_neg_integer()) :: String.t()
  def encode_launches(launch_id), do: selector(:launches) <> uint!(launch_id, @uint256_max)

  @spec encode_launch_id_of_subject(String.t()) :: String.t()
  def encode_launch_id_of_subject(subject),
    do: selector(:launch_id_of_subject) <> address!(subject)

  @doc """
  The five addresses one `launches(launchId)` record names.

  An unknown id is an all-zero record rather than a revert, so the zero launcher
  is answered as `:absent` and never as a launch.
  """
  @spec launch_record([non_neg_integer()]) :: {:ok, map()} | :absent | :error
  def launch_record([0, 0, 0, 0, 0]), do: :absent

  def launch_record([launcher, subject, auction, escrow, treasury]) do
    with {:ok, launcher} <- Abi.word_address(launcher),
         {:ok, subject} <- Abi.word_address(subject),
         {:ok, auction} <- Abi.word_address(auction),
         {:ok, escrow} <- Abi.word_address(escrow),
         {:ok, treasury} <- Abi.word_address(treasury) do
      {:ok,
       %{
         launcher: launcher,
         subject: subject,
         auction: auction,
         escrow: escrow,
         treasury: treasury
       }}
    end
  end

  def launch_record(_words), do: :error

  @doc """
  The signed `int24` a returned word names.

  The word itself is unsigned, so a negative tick spacing arrives sign-extended
  across the whole 256 bits and has to be brought back rather than read as an
  enormous positive number.
  """
  @spec int24(non_neg_integer()) :: {:ok, integer()} | :error
  def int24(word) when is_integer(word) and word >= 0 and word <= @uint256_max do
    value = if word >= @sign_bit, do: word - @two_pow_256, else: word

    if value >= -@int24_bound and value < @int24_bound, do: {:ok, value}, else: :error
  end

  def int24(_word), do: :error

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

  @doc "The one `LaunchFeeCollected` this factory emitted for this launch and payer."
  @spec launch_fee_collected([map()], String.t(), non_neg_integer(), String.t()) ::
          {:ok, %{safe: String.t(), amount: pos_integer()}} | :error
  def launch_fee_collected(logs, factory, launch_id, payer) do
    with {:ok, {[^launch_id, payer_word], [safe_word, amount]}} <-
           Abi.one_event(logs, selector(:launch_fee_collected), factory, 2, 2),
         {:ok, ^payer} <- Abi.word_address(payer_word),
         {:ok, safe} <- Abi.word_address(safe_word),
         true <- amount > 0 do
      {:ok, %{safe: safe, amount: amount}}
    else
      _contradiction -> :error
    end
  end

  @doc "Whether this receipt carries any `LaunchFeeCollected` from this factory at all."
  @spec fee_collected?([map()], String.t()) :: boolean()
  def fee_collected?(logs, factory) when is_list(logs) do
    topic = selector(:launch_fee_collected)

    Enum.any?(logs, fn
      %{"address" => address, "topics" => [^topic | _indexed]} -> Address.equal?(address, factory)
      _log -> false
    end)
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

  # Typed words

  defp address!(address) do
    address
    |> Abi.normalize_address!()
    |> String.trim_leading("0x")
    |> String.pad_leading(64, "0")
  end

  defp uint!(value, max) when is_integer(value) and value >= 0 and value <= max,
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp uint!(_value, _max), do: raise(ArgumentError, "unsigned value is out of range")

  # A string rides as its exact byte length followed by those bytes, right-padded
  # with zeros to a whole number of words.
  defp string_tail!(value) when is_binary(value) do
    if String.valid?(value) and value != "" do
      hex = Base.encode16(value, case: :lower)
      uint!(byte_size(value), @uint256_max) <> String.pad_trailing(hex, padded(value), "0")
    else
      raise ArgumentError, "launch metadata must be nonempty readable text"
    end
  end

  defp padded(value), do: 2 * @word * ceil(byte_size(value) / @word)

  @entries Map.merge(
             Map.merge(@factory_functions, @factory_events),
             @strategy_functions
           )

  defp entry(id), do: Map.fetch!(@entries, id)
end
