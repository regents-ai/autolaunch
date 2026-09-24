defmodule Autolaunch.Robinhood.Positions do
  @moduledoc """
  The bids an account's verified wallets hold on Robinhood memestock auctions,
  read from the chain each time they are asked.

  Nothing about these bids is stored: the launchpad names every auction, each
  auction's own `BidSubmitted` logs name the wallet's bids, and `bids(bidId)`
  says where each bid stands now. Everything is read at one latest block, and
  only the wallets the signed-in account has verified are ever read.

  Where a bid stands follows the auction's own rules. While bidding is open the
  bid is in the auction. Once bidding has ended, the bid waits until the
  launch is finished, since the raise is not final before then. Once the
  launch has failed, an un-exited bid is refundable in full. Once it has
  graduated, an un-exited bid
  still has whatever it did not spend to come back, an amount only the exit
  itself states. An exited bid with tokens filled can claim them from the
  claim block. After a claim clears the stored fill, a positive `TokensClaimed`
  event distinguishes a claimed bid from one returned with nothing filled.
  """

  alias Autolaunch.Actors.Human
  alias Autolaunch.{AuctionBook, LabAbi, TokenHoldings}
  alias Autolaunch.Chain.{Abi, Address, CcaSettlement, Rpc}
  alias Autolaunch.Robinhood.{Auctions, BlockClock, Lab}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi

  @bid_record_words 7

  @type standing ::
          Autolaunch.AuctionBook.standing()
          | :ended
          | :refundable
          | :graduated
          | :returned
          | :filled
          | :claimable
          | :claimed

  @type position :: %{
          auction: String.t(),
          name: String.t(),
          symbol: String.t(),
          stock_symbol: String.t(),
          bid_id: String.t(),
          wallet: String.t(),
          committed: String.t(),
          standing: standing(),
          refundable: String.t() | nil,
          claim_block: non_neg_integer() | nil,
          href: String.t()
        }

  @type reading :: %{positions: [position()], block: pos_integer() | nil}

  @doc """
  Every Robinhood bid the actor's verified wallets hold, newest auction first,
  with the block they were read at. An account with no verified wallet reads
  nothing and names no block.
  """
  @spec read(Human.t()) :: {:ok, reading()} | {:error, :unavailable}
  def read(%Human{} = actor) do
    with {:ok, wallets} <- TokenHoldings.verified_wallets(actor),
         {:ok, reading} <- positions(wallets) do
      {:ok, reading}
    else
      _error -> {:error, :unavailable}
    end
  end

  @none %{positions: [], block: nil}

  defp positions([]), do: {:ok, @none}

  defp positions(wallets) do
    if Lab.configured?(), do: read_positions(wallets), else: {:ok, @none}
  end

  defp read_positions(wallets) do
    with {:ok, config} <- Lab.current(),
         opts = Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, clock} <- BlockClock.read(block, opts),
         {:ok, auctions} <- Auctions.at(config, block, opts) do
      venue = %{abi: Lab.abi!(config, :auction), block: block, clock: clock, opts: opts}
      pinned_positions(auctions, wallets, venue)
    end
  end

  # Log ranges use block numbers; refuse a history that moved since the state
  # reads pinned its hash.
  defp pinned_positions(auctions, wallets, venue) do
    with {:ok, positions} <-
           collect(auctions, fn auction ->
             collect(wallets, &wallet_positions(auction, &1, venue))
           end),
         {:ok, %{"hash" => hash}} <-
           Rpc.request(
             "eth_getBlockByNumber",
             ["0x" <> Integer.to_string(venue.block.number, 16), false],
             venue.opts
           ),
         true <- hash == venue.block.hash do
      {:ok, %{positions: positions, block: venue.block.number}}
    else
      _error -> {:error, :invalid_chain_response}
    end
  end

  defp wallet_positions(auction, wallet, venue) do
    with {:ok, logs} <- bid_logs(auction.auction, wallet, venue),
         do: bid_positions(logs, auction, wallet, venue)
  end

  # Every list in order, or the first read that failed.
  defp collect(items, read) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, found} ->
      case read.(item) do
        {:ok, positions} -> {:cont, {:ok, found ++ positions}}
        error -> {:halt, error}
      end
    end)
  end

  defp bid_logs(auction, wallet, venue) do
    filter = %{
      address: auction,
      fromBlock: "0x0",
      toBlock: "0x" <> Integer.to_string(venue.block.number, 16),
      topics: [
        LabAbi.topic(RobinhoodLabAbi.bid_submitted_signature()),
        nil,
        "0x" <> String.pad_leading(String.slice(wallet, 2..-1//1), 64, "0")
      ]
    }

    case Rpc.request("eth_getLogs", [filter], venue.opts) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  defp bid_positions(logs, auction, wallet, venue) do
    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, found} ->
      with {:ok, submitted} <- bid_submitted(log, auction.auction, wallet, venue),
           {:ok, bid} <- bid_record(submitted, auction.auction, venue),
           {:ok, position} <- position(bid, auction, wallet, venue) do
        {:cont, {:ok, [position | found]}}
      else
        :error -> {:halt, {:error, :invalid_chain_response}}
        error -> {:halt, error}
      end
    end)
  end

  # One `BidSubmitted(bidId, owner, priceQ96, amount)` log for this wallet.
  defp bid_submitted(log, auction, wallet, venue) do
    with {:ok, {[bid_id, owner_word], [price_q96, amount]}} <-
           LabAbi.event_words(
             venue.abi,
             RobinhoodLabAbi.bid_submitted_signature(),
             [log],
             auction
           ),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(owner, wallet) do
      {:ok, %{bid_id: bid_id, owner: owner, max_price_q96: price_q96, amount: amount}}
    else
      _ -> :error
    end
  end

  # `bids(bidId)`: startBlock, startCumulativeMps, exitedBlock, maxPrice, owner,
  # amountQ96, tokensFilled. The exit block and the tokens filled are the bid's
  # current state.
  defp bid_record(submitted, auction, venue) do
    with {:ok, [_start, _mps, exited_block, _max_price, _owner, _amount_q96, tokens_filled]} <-
           Rpc.call_words(
             auction,
             LabAbi.encode(venue.abi, "bids(uint256)", [submitted.bid_id]),
             venue.block,
             @bid_record_words,
             venue.opts
           ) do
      {:ok, Map.merge(submitted, %{exited_block: exited_block, tokens_filled: tokens_filled})}
    end
  end

  defp position(bid, auction, wallet, venue) do
    with {:ok, standing, refundable, claim_block} <- standing(bid, auction, venue) do
      {:ok,
       %{
         auction: auction.auction,
         name: auction.name,
         symbol: auction.symbol,
         stock_symbol: auction.stock_symbol,
         bid_id: Integer.to_string(bid.bid_id),
         wallet: wallet,
         committed: Rpc.format_units(bid.amount, auction.stock_decimals),
         standing: standing,
         refundable: refundable && Rpc.format_units(refundable, auction.stock_decimals),
         claim_block: claim_block,
         href: "/robinhood/auctions/#{auction.auction}"
       }}
    end
  end

  # The auction's own rules, in order: an un-exited bid is in the auction until
  # the end block, buying, sharing or outbid against the stored clearing price;
  # after it, the raise is only final once the launch is
  # finished, so the bid waits on that; a failed launch refunds it in full and
  # a graduated one owes it whatever it did not spend, which its exit states;
  # an exited bid with fill claims from the claim block.
  defp standing(%{exited_block: 0} = bid, %{state: state} = auction, _venue)
       when state in [:created, :active],
       do:
         {:ok,
          AuctionBook.standing(bid.max_price_q96, %{clearing_q96: auction.clearing_price_q96}),
          nil, nil}

  defp standing(%{exited_block: 0}, %{state: :ended}, _venue), do: {:ok, :ended, nil, nil}

  defp standing(%{exited_block: 0, amount: amount}, %{state: :failed}, _venue),
    do: {:ok, :refundable, amount, nil}

  defp standing(%{exited_block: 0}, %{state: :graduated}, _venue),
    do: {:ok, :graduated, nil, nil}

  defp standing(%{tokens_filled: 0} = bid, auction, venue) do
    with {:ok, claimed?} <- claimed?(bid, auction.auction, venue) do
      {:ok, if(claimed?, do: :claimed, else: :returned), nil, nil}
    end
  end

  defp standing(_bid, auction, venue) do
    with {:ok, claim_block} <-
           Rpc.call_uint(
             auction.auction,
             LabAbi.encode(venue.abi, "claimBlock()", []),
             venue.block,
             venue.opts
           ) do
      if venue.clock >= claim_block,
        do: {:ok, :claimable, nil, claim_block},
        else: {:ok, :filled, nil, claim_block}
    end
  end

  defp claimed?(bid, auction, venue) do
    filter = %{
      address: auction,
      fromBlock: "0x0",
      toBlock: "0x" <> Integer.to_string(venue.block.number, 16),
      topics: [
        LabAbi.topic(CcaSettlement.tokens_claimed_signature()),
        "0x" <> String.pad_leading(Integer.to_string(bid.bid_id, 16), 64, "0"),
        "0x" <> String.pad_leading(String.slice(bid.owner, 2..-1//1), 64, "0")
      ]
    }

    case Rpc.request("eth_getLogs", [filter], venue.opts) do
      {:ok, logs} when is_list(logs) -> claimed_in?(logs, bid, auction, venue)
      {:ok, _other} -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  defp claimed_in?(logs, bid, auction, venue) do
    Enum.reduce_while(logs, {:ok, false}, fn log, {:ok, claimed?} ->
      case claimed_log(log, bid, auction, venue) do
        {:ok, tokens} -> {:cont, {:ok, claimed? or tokens > 0}}
        error -> {:halt, error}
      end
    end)
  end

  # The tokens one claim log delivered, or an invalid response for a log that
  # is removed, outside the pinned range or not this bid's claim.
  defp claimed_log(log, bid, auction, venue) do
    with %{"removed" => false, "blockNumber" => "0x" <> number} <- log,
         {number, ""} <- Integer.parse(number, 16),
         true <- number >= 0 and number <= venue.block.number,
         {:ok, %{tokens_claimed: tokens}} <-
           CcaSettlement.claimed(venue.abi, [log], auction, bid.bid_id, bid.owner) do
      {:ok, tokens}
    else
      _invalid -> {:error, :invalid_chain_response}
    end
  end
end
