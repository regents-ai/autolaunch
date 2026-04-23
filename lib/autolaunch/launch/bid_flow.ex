defmodule Autolaunch.Launch.BidFlow do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Contract, as: CCAContract
  alias Autolaunch.CCA.Market, as: CCAMarket
  alias Autolaunch.CCA.QuoteEngine
  alias Autolaunch.Launch.AuctionDetails
  alias Autolaunch.Launch.Bid
  alias Autolaunch.Launch.Core
  alias Autolaunch.Repo

  def quote_bid(auction_id, attrs, current_human \\ nil) do
    with auction when is_map(auction) <- AuctionDetails.get_auction(auction_id, current_human),
         {:ok, amount_decimal} <- Core.required_decimal(Map.get(attrs, :amount), :amount_required),
         {:ok, max_price_decimal} <-
           Core.required_decimal(Map.get(attrs, :max_price), :max_price_required),
         {:ok, amount_wei} <- Core.decimal_to_wei(amount_decimal),
         {:ok, max_price_q96} <- Core.decimal_price_to_q96(max_price_decimal),
         {:ok, raw_quote} <-
           QuoteEngine.quote(auction.chain_id, auction.auction_address, amount_wei, max_price_q96) do
      time_remaining_seconds = Core.time_remaining_seconds(auction.ends_at)
      owner_address = current_human && Core.primary_wallet_address(current_human)

      tx_request =
        if owner_address do
          case CCAMarket.build_submit_tx_request(
                 auction,
                 owner_address,
                 amount_wei,
                 max_price_q96
               ) do
            {:ok, request} -> Core.serialize_tx_request(request)
            _ -> nil
          end
        end

      quote = %{
        auction_id: auction.id,
        amount: Core.decimal_string(amount_decimal),
        max_price: Core.decimal_string(max_price_decimal, 8),
        current_clearing_price: Core.q96_price_to_string(raw_quote.current_clearing_price_q96),
        projected_clearing_price:
          Core.q96_price_to_string(raw_quote.projected_clearing_price_q96),
        quote_mode: raw_quote.quote_mode,
        would_be_active_now: raw_quote.would_be_active_now,
        status_band: raw_quote.status_band,
        estimated_tokens_if_end_now:
          Core.token_units_to_string(raw_quote.estimated_tokens_if_end_now_units),
        estimated_tokens_if_no_other_bids_change:
          Core.token_units_to_string(raw_quote.estimated_tokens_if_no_other_bids_change_units),
        inactive_above_price: Core.q96_price_to_string(raw_quote.inactive_above_price_q96),
        time_remaining_seconds: time_remaining_seconds,
        warnings: raw_quote.warnings,
        tx_request: tx_request
      }

      {:ok, quote}
    else
      nil -> {:error, :auction_not_found}
      {:error, _} = error -> error
    end
  end

  def place_bid(auction_id, attrs, %HumanUser{} = human) do
    with :ok <- Core.ensure_authenticated_human(human),
         {:ok, wallet_address} <- Core.required_address(human.wallet_address),
         {:ok, tx_hash} <- Core.required_tx_hash(Map.get(attrs, :tx_hash)),
         {:ok, auction} <- fetch_auction_for_bid(auction_id, human),
         {:ok, amount_decimal} <- Core.required_decimal(Map.get(attrs, :amount), :amount_required),
         {:ok, max_price_decimal} <-
           Core.required_decimal(Map.get(attrs, :max_price), :max_price_required),
         {:ok, amount_wei} <- Core.decimal_to_wei(amount_decimal),
         {:ok, max_price_q96} <- Core.decimal_price_to_q96(max_price_decimal),
         {:ok, snapshot} <- CCAContract.snapshot(auction.chain_id, auction.auction_address),
         {:ok, registration} <-
           CCAMarket.register_submitted_bid(
             snapshot,
             tx_hash,
             wallet_address,
             amount_wei,
             max_price_q96
           ) do
      bid_id = local_bid_id(auction_id, registration.onchain_bid_id)
      quote_snapshot = build_bid_quote_snapshot(attrs, snapshot)
      now = DateTime.utc_now()

      bid_attrs = %{
        bid_id: bid_id,
        privy_user_id: human.privy_user_id,
        owner_address: wallet_address,
        auction_id: auction_id,
        auction_address: auction.auction_address,
        chain_id: auction.chain_id,
        agent_id: auction.agent_id,
        agent_name: auction.agent_name,
        network: auction.network,
        onchain_bid_id: Integer.to_string(registration.onchain_bid_id),
        submit_tx_hash: registration.submit_tx_hash,
        submit_block_number: registration.submit_block_number,
        amount: amount_decimal,
        max_price: max_price_decimal,
        current_clearing_price: Core.q96_to_decimal(snapshot.checkpoint.clearing_price_q96),
        current_status: "active",
        estimated_tokens_if_end_now:
          Core.decimal_from_string(Map.get(attrs, :estimated_tokens_if_end_now)),
        estimated_tokens_if_no_other_bids_change:
          Core.decimal_from_string(Map.get(attrs, :estimated_tokens_if_no_other_bids_change)),
        inactive_above_price: Core.decimal_from_string(Map.get(attrs, :inactive_above_price)),
        quote_snapshot: quote_snapshot,
        inserted_at: now,
        updated_at: now
      }

      {:ok, _bid} =
        Repo.insert(
          struct(Bid, bid_attrs),
          on_conflict: [
            set: [
              submit_tx_hash: registration.submit_tx_hash,
              submit_block_number: registration.submit_block_number,
              amount: amount_decimal,
              max_price: max_price_decimal,
              current_clearing_price: Core.q96_to_decimal(snapshot.checkpoint.clearing_price_q96),
              current_status: "active",
              estimated_tokens_if_end_now:
                Core.decimal_from_string(Map.get(attrs, :estimated_tokens_if_end_now)),
              estimated_tokens_if_no_other_bids_change:
                Core.decimal_from_string(
                  Map.get(attrs, :estimated_tokens_if_no_other_bids_change)
                ),
              inactive_above_price:
                Core.decimal_from_string(Map.get(attrs, :inactive_above_price)),
              quote_snapshot: quote_snapshot,
              updated_at: now
            ]
          ],
          conflict_target: [:auction_id, :onchain_bid_id]
        )

      with %Bid{} = tracked_bid <- Repo.get(Bid, bid_id) do
        {:ok, decorate_bid_position(tracked_bid, human)}
      else
        _ -> {:error, :bid_tracking_failed}
      end
    else
      {:error, :transaction_pending} -> {:error, :transaction_pending}
      {:error, :transaction_failed} -> {:error, :transaction_failed}
      {:error, _} = error -> error
    end
  end

  def place_bid(_auction_id, _attrs, _human), do: {:error, :unauthorized}

  def list_positions(human, filters \\ %{})

  def list_positions(nil, _filters), do: []

  def list_positions(%HumanUser{} = human, filters) do
    wallet_addresses = Core.linked_wallet_addresses(human)

    with {:ok, active_chain_id} <- Core.launch_chain_id() do
      bids =
        Repo.all(
          from bid in Bid,
            where: bid.owner_address in ^wallet_addresses and bid.chain_id == ^active_chain_id,
            order_by: [desc: bid.inserted_at]
        )

      bids
      |> Enum.map(&decorate_bid_position(&1, human))
      |> filter_positions(filters)
    else
      _ -> []
    end
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
    Ecto.QueryError -> []
  end

  def exit_bid(bid_id, attrs, %HumanUser{} = human) do
    with :ok <- Core.ensure_authenticated_human(human),
         {:ok, wallet_address} <- Core.required_address(human.wallet_address),
         {:ok, tx_hash} <- Core.required_tx_hash(Map.get(attrs, :tx_hash)),
         %Bid{} = bid <- Repo.get(Bid, bid_id),
         :ok <- ensure_bid_belongs_to_owner(bid, wallet_address),
         {:ok, auction} <- fetch_auction_for_bid(bid.auction_id, human),
         {:ok, snapshot} <- CCAContract.snapshot(auction.chain_id, auction.auction_address),
         {:ok, onchain_bid_id} <- parse_onchain_bid_id(bid.onchain_bid_id),
         {:ok, registration} <-
           CCAMarket.register_exit(snapshot, tx_hash, wallet_address, onchain_bid_id),
         {:ok, _updated_bid} <-
           bid
           |> Bid.update_changeset(%{
             current_status: "exited",
             exit_tx_hash: registration.exit_tx_hash,
             exited_at: DateTime.utc_now()
           })
           |> Repo.update() do
      {:ok, decorate_bid_position(Repo.get!(Bid, bid.bid_id), human)}
    else
      nil -> {:error, :not_found}
      {:error, :transaction_pending} -> {:error, :transaction_pending}
      {:error, :transaction_failed} -> {:error, :transaction_failed}
      {:error, _} = error -> error
    end
  end

  def exit_bid(_bid_id, _attrs, _human), do: {:error, :unauthorized}

  def return_bid(bid_id, attrs, current_human), do: exit_bid(bid_id, attrs, current_human)

  def claim_bid(bid_id, attrs, %HumanUser{} = human) do
    with :ok <- Core.ensure_authenticated_human(human),
         {:ok, wallet_address} <- Core.required_address(human.wallet_address),
         {:ok, tx_hash} <- Core.required_tx_hash(Map.get(attrs, :tx_hash)),
         %Bid{} = bid <- Repo.get(Bid, bid_id),
         :ok <- ensure_bid_belongs_to_owner(bid, wallet_address),
         {:ok, auction} <- fetch_auction_for_bid(bid.auction_id, human),
         {:ok, snapshot} <- CCAContract.snapshot(auction.chain_id, auction.auction_address),
         {:ok, onchain_bid_id} <- parse_onchain_bid_id(bid.onchain_bid_id),
         {:ok, registration} <-
           CCAMarket.register_claim(snapshot, tx_hash, wallet_address, onchain_bid_id),
         {:ok, _updated_bid} <-
           bid
           |> Bid.update_changeset(%{
             current_status: "claimed",
             claim_tx_hash: registration.claim_tx_hash,
             claimed_at: DateTime.utc_now()
           })
           |> Repo.update() do
      {:ok, decorate_bid_position(Repo.get!(Bid, bid.bid_id), human)}
    else
      nil -> {:error, :not_found}
      {:error, :transaction_pending} -> {:error, :transaction_pending}
      {:error, :transaction_failed} -> {:error, :transaction_failed}
      {:error, _} = error -> error
    end
  end

  def claim_bid(_bid_id, _attrs, _human), do: {:error, :unauthorized}

  defp fetch_auction_for_bid(auction_id, current_human) do
    case AuctionDetails.get_auction(auction_id, current_human) do
      nil -> {:error, :auction_not_found}
      auction -> {:ok, auction}
    end
  end

  defp local_bid_id(auction_id, onchain_bid_id) when is_integer(onchain_bid_id) do
    "#{auction_id}:#{onchain_bid_id}"
  end

  defp build_bid_quote_snapshot(attrs, snapshot) do
    %{
      "quote_mode" => "onchain_exact_v1",
      "current_clearing_price" =>
        Map.get(attrs, :current_clearing_price) ||
          Core.q96_price_to_string(snapshot.checkpoint.clearing_price_q96),
      "estimated_tokens_if_end_now" => Map.get(attrs, :estimated_tokens_if_end_now),
      "estimated_tokens_if_no_other_bids_change" =>
        Map.get(attrs, :estimated_tokens_if_no_other_bids_change),
      "inactive_above_price" => Map.get(attrs, :inactive_above_price),
      "status_band" => Map.get(attrs, :status_band),
      "projected_clearing_price" => Map.get(attrs, :projected_clearing_price)
    }
  end

  defp stored_bid_clearing_price(auction, bid) do
    if auction[:current_clearing_price],
      do: auction.current_clearing_price,
      else: Core.decimal_string(bid.current_clearing_price)
  end

  defp next_action_label(nil, "claimable"), do: "Claim purchased tokens."
  defp next_action_label(nil, "exited"), do: "Position has already exited."
  defp next_action_label(nil, "claimed"), do: "Tokens already claimed."

  defp next_action_label(nil, "returnable"),
    do: "Return the remaining USDC from this failed auction."

  defp next_action_label(nil, "inactive"), do: "Monitor the auction until an exit becomes valid."
  defp next_action_label(nil, _status), do: "No wallet action available yet."

  defp next_action_label(%{claim_action: %{}} = _market_position, _status),
    do: "Claim purchased tokens now."

  defp next_action_label(%{exit_action: %{type: :exit_partially_filled_bid}}, _status),
    do: "Exit this bid with checkpoint hints."

  defp next_action_label(%{exit_action: %{type: :exit_bid}}, _status),
    do: "Exit this bid and settle the refund."

  defp next_action_label(_market_position, "returnable"),
    do: "This auction missed its minimum raise. Return your USDC."

  defp next_action_label(_market_position, "inactive"),
    do: "Outbid for now. Exit becomes available only once the contract allows it."

  defp next_action_label(_market_position, "borderline"),
    do: "At the clearing boundary. Stay alert for displacement."

  defp next_action_label(_market_position, _status), do: "Bid is still participating."

  defp returnable_bid?(
         %{auction_outcome: "failed_minimum"},
         %{exit_action: %{type: :exit_bid}},
         status
       )
       when status not in ["claimed", "exited"],
       do: true

  defp returnable_bid?(_auction, _market_position, _status), do: false

  defp filter_positions(positions, filters) do
    case Map.get(filters, :status) do
      nil -> positions
      "" -> positions
      status -> Enum.filter(positions, &(&1.status == status))
    end
  end

  defp decorate_bid_position(%Bid{} = bid, current_human) do
    auction = AuctionDetails.get_auction(bid.auction_id, current_human) || %{}

    market_position =
      with %{auction_address: auction_address, chain_id: chain_id}
           when is_binary(auction_address) and is_integer(chain_id) <- auction,
           {:ok, snapshot} <- CCAContract.snapshot(chain_id, auction_address),
           {:ok, market_position} <- CCAMarket.sync_bid_position(snapshot, bid) do
        market_position
      else
        _ -> nil
      end

    derived_status =
      if market_position,
        do: market_position.current_status,
        else: derive_position_status(bid, auction)

    derived_status =
      if returnable_bid?(auction, market_position, derived_status) do
        "returnable"
      else
        derived_status
      end

    return_action =
      if derived_status == "returnable" do
        Core.serialize_action_request(market_position && market_position.exit_action)
      else
        nil
      end

    tx_actions =
      if market_position do
        %{
          return_usdc: return_action,
          exit: Core.serialize_action_request(market_position.exit_action),
          claim: Core.serialize_action_request(market_position.claim_action)
        }
      else
        %{return_usdc: nil, exit: nil, claim: nil}
      end

    %{
      bid_id: bid.bid_id,
      onchain_bid_id: bid.onchain_bid_id,
      auction_id: bid.auction_id,
      agent_id: bid.agent_id,
      agent_name: bid.agent_name,
      chain: bid.network,
      status: derived_status,
      amount: Core.decimal_string(bid.amount),
      max_price: Core.decimal_string(bid.max_price),
      current_clearing_price:
        if(market_position,
          do: Core.q96_price_to_string(market_position.current_clearing_price_q96),
          else: stored_bid_clearing_price(auction, bid)
        ),
      estimated_tokens_if_end_now: Core.decimal_string(bid.estimated_tokens_if_end_now, 2),
      estimated_tokens_if_no_other_bids_change:
        Core.decimal_string(bid.estimated_tokens_if_no_other_bids_change, 2),
      inactive_above_price: Core.decimal_string(bid.inactive_above_price),
      tokens_filled:
        if(market_position,
          do: Core.token_units_to_string(market_position.onchain_bid.tokens_filled_units),
          else: "0"
        ),
      next_action_label: next_action_label(market_position, derived_status),
      return_action: return_action,
      tx_actions: tx_actions,
      auction: auction,
      inserted_at: Core.iso(bid.inserted_at)
    }
  end

  defp derive_position_status(%Bid{claimed_at: %DateTime{}}, _auction), do: "claimed"
  defp derive_position_status(%Bid{exited_at: %DateTime{}}, _auction), do: "exited"

  defp derive_position_status(%Bid{} = _bid, %{status: status})
       when status in ["settled", "pending-claim"],
       do: "claimable"

  defp derive_position_status(%Bid{} = bid, auction) do
    clearing =
      Core.parse_decimal(
        auction[:current_clearing_price] || Core.decimal_string(bid.current_clearing_price)
      )

    compare = Decimal.compare(bid.max_price, clearing)

    cond do
      compare == :lt ->
        "inactive"

      Decimal.compare(bid.max_price, Decimal.mult(clearing, Decimal.new("1.03"))) == :lt ->
        "borderline"

      true ->
        "active"
    end
  end

  defp ensure_bid_belongs_to_owner(%Bid{owner_address: owner_address}, wallet_address) do
    if owner_address == Core.normalize_address(wallet_address),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp parse_onchain_bid_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_onchain_bid_id}
    end
  end

  defp parse_onchain_bid_id(_value), do: {:error, :invalid_onchain_bid_id}
end
