defmodule Autolaunch.Chain.AuctionAbi do
  @moduledoc """
  The canonical Continuous Clearing Auction bid interface, derived from source.

  Everything here comes from Uniswap/continuous-clearing-auction
  `7d7602d257733315434570f2a0c2f94f1c7b207a`: `submitBid` from
  `src/interfaces/IContinuousClearingAuction.sol:136-142`, `currency` from line
  211, and `BidSubmitted` from line 103. The four-argument overload is absent on
  purpose — it defaults `prevTickPriceQ96` to the floor and walks every tick.
  """

  alias Autolaunch.Chain.Abi

  @abi_path Path.expand("../../../contracts/abi/continuous-clearing-auction.json", __DIR__)
  @external_resource @abi_path
  @abi @abi_path |> File.read!() |> Jason.decode!()

  @submit_bid "submitBid(uint256,uint128,address,uint256,bytes)"
  @submit_bid_selector "0xa52c8728"
  @currency "currency()"
  @bid_submitted "BidSubmitted(uint256,address,uint256,uint128)"

  @uint128_max Integer.pow(2, 128) - 1
  @uint256_max Integer.pow(2, 256) - 1

  # `hookData` is always empty: this auction family validates no hook data, and
  # a bid that carried any would be a different reviewed action.
  @empty_bytes_offset 160

  @after_compile __MODULE__

  @doc false
  def __after_compile__(_env, _bytecode) do
    Abi.declared!(@abi, "function", @submit_bid)
    Abi.declared!(@abi, "function", @currency)
    Abi.declared!(@abi, "event", @bid_submitted)
  end

  @doc "Exact calldata for the canonical five-argument bid with empty hook data."
  @spec encode_submit_bid(non_neg_integer(), pos_integer(), String.t(), non_neg_integer()) ::
          String.t()
  def encode_submit_bid(max_price_q96, amount, owner, prev_tick_price_q96)
      when is_integer(amount) and amount in 1..@uint128_max do
    @submit_bid_selector <>
      word(max_price_q96) <>
      word(amount) <>
      address_word(owner) <>
      word(prev_tick_price_q96) <>
      word(@empty_bytes_offset) <>
      word(0)
  end

  @spec bid_submitted_topic() :: String.t()
  def bid_submitted_topic, do: Abi.topic0(@bid_submitted)

  @doc """
  The bid id of the one `BidSubmitted` this receipt records for `owner`.

  Emitter, topic, the two indexed words and the two data words all have to be
  exact, and the decoded price and `uint128` amount have to be the reviewed ones,
  so a receipt whose logs describe another bid is `:error` rather than a bid id.
  """
  @spec submitted_bid_id([map()], String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | :error
  def submitted_bid_id(logs, auction, owner, price_q96, amount) do
    with {:ok, {[id, owner_word], [^price_q96, ^amount]}} <-
           Abi.one_event(logs, bid_submitted_topic(), auction, 2, 2),
         {:ok, ^owner} <- Abi.word_address(owner_word) do
      {:ok, id}
    else
      _contradiction -> :error
    end
  end

  defp address_word(address),
    do:
      address
      |> Abi.normalize_address!()
      |> String.trim_leading("0x")
      |> String.pad_leading(64, "0")

  defp word(value) when is_integer(value) and value in 0..@uint256_max,
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")
end
