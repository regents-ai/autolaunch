defmodule Autolaunch.LabPositions do
  @moduledoc """
  Keeps the site's bid positions truthful after an auction has ended.

  Both lab market feeds call `read/6` for every auction whose end block has
  passed: each position this site holds with an on-chain bid id is read back
  from the auction's own `bids(bidId)`, and its status follows the contract:
  `returnable` while the bid can still be exited, `claimable` once exited with
  fill and the claim block reached, `returned` when exited with nothing left to
  claim yet, `claimed` once the fill has been taken. `project/1` writes the
  statuses that changed inside the feed's own transaction.
  """

  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.Bid
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi

  @actor %System{}
  @domain Autolaunch
  @q96 79_228_162_514_264_337_593_543_950_336

  @type reading :: %{bid_id: String.t(), status: String.t(), position: Bid.t()}

  @doc "The positions of one ended auction, read from the fork at one block."
  @spec read([map()], [Bid.t()], String.t(), map(), map(), keyword()) ::
          {:ok, [reading()]} | {:error, term()}
  def read(abi, positions, auction_address, market, block, opts) do
    if block.number >= market.end_block do
      Enum.reduce_while(positions, {:ok, []}, fn position, {:ok, readings} ->
        case chain_bid(abi, auction_address, position, block, opts) do
          {:ok, bid} ->
            {:cont, {:ok, [reading(position, bid, market, block) | readings]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    else
      {:ok, []}
    end
  end

  @doc "Every site position of one auction that names an on-chain bid id."
  @spec positions(String.t()) :: {:ok, [Bid.t()]} | {:error, term()}
  def positions(auction_id) do
    Bid
    # System projection of the fork's own record; no actor.
    |> Ash.Query.for_read(:mine, %{}, domain: @domain, authorize?: false)
    |> Ash.Query.filter(auction_id == ^auction_id and not is_nil(onchain_bid_id))
    |> Ash.read(domain: @domain, authorize?: false)
  end

  @doc "Writes the readings whose status differs from the stored one. Returns whether anything changed."
  @spec project([reading()]) :: {:ok, boolean()} | {:error, term()}
  def project(readings) do
    readings
    |> Enum.filter(&(&1.status != &1.position.status))
    |> Enum.reduce_while({:ok, false}, fn reading, {:ok, _changed} ->
      case write(reading) do
        {:ok, _bid} -> {:cont, {:ok, true}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The feed's reading was taken before this write, and a wallet verification
  # may have recorded the same settlement meanwhile. The row is re-read under a
  # lock inside the write transaction and its recorded amounts are kept; only a
  # status the chain now contradicts is corrected.
  defp write(%{position: stale, status: status} = reading) do
    Autolaunch.Repo.transaction(fn ->
      with {:ok, position} <- locked(stale.bid_id),
           false <- position.status == status,
           {:ok, bid} <- upsert(position, status, reading) do
        bid
      else
        true -> stale
        {:error, reason} -> Autolaunch.Repo.rollback(reason)
      end
    end)
  end

  defp locked(bid_id) do
    Bid
    # System projection of the fork's own record; no actor.
    |> Ash.Query.for_read(:mine, %{}, domain: @domain, authorize?: false)
    |> Ash.Query.filter(bid_id == ^bid_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: @domain, authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :bid_not_found}
      other -> other
    end
  end

  defp upsert(position, status, reading) do
    Bid
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        bid_id: position.bid_id,
        auction_id: position.auction_id,
        owner_address: position.owner_address,
        amount: position.amount,
        max_price: position.max_price,
        current_clearing_price: position.current_clearing_price,
        estimated_tokens_if_end_now: position.estimated_tokens_if_end_now,
        status: status,
        exited_at: exited_at(position, reading),
        claimed_at: claimed_at(position, status),
        auction_address: position.auction_address,
        onchain_bid_id: position.onchain_bid_id,
        currency_refunded: position.currency_refunded,
        tokens_filled: tokens_filled(position, reading),
        tokens_claimed: position.tokens_claimed
      },
      domain: @domain,
      actor: @actor
    )
    |> Ash.create(domain: @domain, actor: @actor)
  end

  defp exited_at(%{exited_at: nil}, %{exited: true}), do: DateTime.utc_now()
  defp exited_at(position, _reading), do: position.exited_at

  defp claimed_at(%{claimed_at: nil}, "claimed"), do: DateTime.utc_now()
  defp claimed_at(position, _status), do: position.claimed_at

  # The fill the auction records survives the claim zeroing it on chain.
  defp tokens_filled(_position, %{exited: true, tokens_filled: filled}) when filled > 0,
    do: Rpc.format_units(filled, 18)

  defp tokens_filled(position, _reading), do: position.tokens_filled

  defp chain_bid(abi, auction_address, position, block, opts) do
    with {:ok, [_start, _mps, exited_block, _max_price, owner_word, amount_q96, filled]} <-
           Rpc.call_words(
             auction_address,
             LabAbi.encode(abi, "bids(uint256)", [String.to_integer(position.onchain_bid_id)]),
             block,
             7,
             opts
           ),
         {:ok, _owner} <- Abi.word_address(owner_word) do
      {:ok, %{exited: exited_block != 0, tokens_filled: filled, amount: div(amount_q96, @q96)}}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reading(position, bid, market, block) do
    %{
      bid_id: position.bid_id,
      position: position,
      exited: bid.exited,
      tokens_filled: bid.tokens_filled,
      status: status(position, bid, market, block)
    }
  end

  # The contract's own rules, in order: an unexited bid can be exited after the
  # end block; an exited bid with fill can claim once the claim block passes;
  # an exited bid whose recorded fill has gone to zero has been claimed.
  defp status(_position, %{exited: false}, _market, _block), do: "returnable"

  defp status(_position, %{exited: true, tokens_filled: filled}, market, block) when filled > 0,
    do: if(block.number >= market.claim_block, do: "claimable", else: "returned")

  defp status(position, %{exited: true, tokens_filled: 0}, _market, _block) do
    if position.status in ["claimable", "claimed"] or recorded_fill?(position),
      do: "claimed",
      else: "returned"
  end

  defp recorded_fill?(%{tokens_filled: filled}) when is_binary(filled) and filled != "",
    do: Decimal.gt?(Decimal.new(filled), 0)

  defp recorded_fill?(_position), do: false
end
