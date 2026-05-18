defmodule Autolaunch.CCA.Market do
  @moduledoc false

  alias Autolaunch.BaseChain
  alias Autolaunch.CCA.Abi
  alias Autolaunch.CCA.Contract
  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts.ActionParams

  def build_submit_tx_request(auction, owner_address, amount_wei, max_price_q96) do
    {:ok,
     %{
       chain_id: auction.chain_id,
       to: auction.auction_address,
       value_hex: to_hex_quantity(0),
       data: Abi.encode_submit_bid(max_price_q96, amount_wei, owner_address),
       approval: %{
         token: auction_quote_token(auction),
         spender: auction.auction_address,
         amount: Integer.to_string(amount_wei),
         data: Abi.encode_approve(auction.auction_address, amount_wei)
       }
     }}
  end

  defp auction_quote_token(%{auction_quote_token_address: address}) when is_binary(address),
    do: String.downcase(address)

  defp auction_quote_token(%{chain_id: chain_id}),
    do: BaseChain.canonical_regent_address!(chain_id)

  def build_exit_tx_request(auction, onchain_bid_id, action) do
    data =
      case action do
        %{type: :exit_bid} ->
          Abi.encode_exit_bid(onchain_bid_id)

        %{
          type: :exit_partially_filled_bid,
          last_fully_filled_checkpoint_block: last_block,
          outbid_block: outbid_block
        } ->
          Abi.encode_exit_partially_filled_bid(onchain_bid_id, last_block, outbid_block)
      end

    {:ok,
     %{
       chain_id: auction.chain_id,
       to: auction.auction_address,
       value_hex: to_hex_quantity(0),
       data: data
     }}
  end

  def build_claim_tx_request(auction, onchain_bid_id) do
    {:ok,
     %{
       chain_id: auction.chain_id,
       to: auction.auction_address,
       value_hex: to_hex_quantity(0),
       data: Abi.encode_claim_tokens(onchain_bid_id)
     }}
  end

  def register_submitted_bid(
        snapshot,
        tx_hash,
        expected_owner_address,
        expected_amount_wei,
        expected_max_price_q96
      ) do
    with {:ok, receipt} <- Rpc.tx_receipt(snapshot.chain_id, tx_hash),
         :ok <- ensure_successful_receipt(receipt),
         :ok <- ensure_receipt_target(receipt, snapshot.auction_address),
         :ok <- ensure_receipt_sender(receipt, expected_owner_address),
         {:ok, bid_event} <-
           find_bid_submitted_event(
             receipt.logs,
             snapshot.auction_address,
             expected_owner_address,
             expected_amount_wei,
             expected_max_price_q96
           ),
         {:ok, onchain_bid} <-
           Contract.bid(snapshot.chain_id, snapshot.auction_address, bid_event.onchain_bid_id),
         :ok <- ensure_bid_owner(onchain_bid, expected_owner_address) do
      {:ok,
       %{
         onchain_bid_id: bid_event.onchain_bid_id,
         submit_block_number: receipt.block_number,
         submit_tx_hash: normalize_hash(tx_hash),
         onchain_bid: onchain_bid,
         receipt: receipt
       }}
    end
  end

  def register_exit(snapshot, tx_hash, expected_owner_address, onchain_bid_id) do
    with {:ok, receipt} <- Rpc.tx_receipt(snapshot.chain_id, tx_hash),
         :ok <- ensure_successful_receipt(receipt),
         :ok <- ensure_receipt_target(receipt, snapshot.auction_address),
         :ok <- ensure_receipt_sender(receipt, expected_owner_address),
         {:ok, _event} <-
           find_bid_exited_event(
             receipt.logs,
             snapshot.auction_address,
             expected_owner_address,
             onchain_bid_id
           ),
         {:ok, onchain_bid} <-
           Contract.bid(snapshot.chain_id, snapshot.auction_address, onchain_bid_id) do
      {:ok,
       %{
         exit_tx_hash: normalize_hash(tx_hash),
         onchain_bid: onchain_bid,
         receipt: receipt
       }}
    end
  end

  def register_claim(snapshot, tx_hash, expected_owner_address, onchain_bid_id) do
    with {:ok, receipt} <- Rpc.tx_receipt(snapshot.chain_id, tx_hash),
         :ok <- ensure_successful_receipt(receipt),
         :ok <- ensure_receipt_target(receipt, snapshot.auction_address),
         :ok <- ensure_receipt_sender(receipt, expected_owner_address),
         {:ok, _event} <-
           find_tokens_claimed_event(
             receipt.logs,
             snapshot.auction_address,
             expected_owner_address,
             onchain_bid_id
           ),
         {:ok, onchain_bid} <-
           Contract.bid(snapshot.chain_id, snapshot.auction_address, onchain_bid_id) do
      {:ok,
       %{
         claim_tx_hash: normalize_hash(tx_hash),
         onchain_bid: onchain_bid,
         receipt: receipt
       }}
    end
  end

  def sync_bid_position(snapshot, tracked_bid) do
    with {:ok, onchain_bid_id} <- parse_onchain_bid_id(tracked_bid.onchain_bid_id),
         {:ok, onchain_bid} <-
           Contract.bid(snapshot.chain_id, snapshot.auction_address, onchain_bid_id),
         :ok <- ensure_bid_owner(onchain_bid, tracked_bid.owner_address) do
      checkpoint_history =
        case Contract.checkpoint_history(
               snapshot.chain_id,
               snapshot.auction_address,
               onchain_bid.start_block,
               snapshot.block_number
             ) do
          {:ok, history} -> history
          {:error, _} -> []
        end

      exit_action =
        exit_action(
          snapshot,
          onchain_bid_id,
          onchain_bid,
          checkpoint_history,
          tracked_bid.owner_address
        )

      claim_action =
        claim_action(snapshot, onchain_bid_id, onchain_bid, tracked_bid.owner_address)

      {:ok,
       %{
         snapshot: snapshot,
         onchain_bid_id: onchain_bid_id,
         onchain_bid: onchain_bid,
         current_status: current_status(snapshot, onchain_bid, tracked_bid),
         current_clearing_price_q96: snapshot.checkpoint.clearing_price_q96,
         tokens_filled_units: onchain_bid.tokens_filled_units,
         exit_action: exit_action,
         claim_action: claim_action
       }}
    end
  end

  defp current_status(_snapshot, _onchain_bid, %{claimed_at: %DateTime{}}), do: "claimed"

  defp current_status(snapshot, onchain_bid, _tracked_bid) do
    cond do
      onchain_bid.exited_block > 0 and onchain_bid.tokens_filled_units > 0 and
          snapshot.block_number >= snapshot.claim_block ->
        "claimable"

      onchain_bid.exited_block > 0 ->
        "exited"

      onchain_bid.max_price_q96 > snapshot.checkpoint.clearing_price_q96 ->
        "active"

      onchain_bid.max_price_q96 == snapshot.checkpoint.clearing_price_q96 ->
        "borderline"

      true ->
        "inactive"
    end
  end

  defp exit_action(snapshot, onchain_bid_id, onchain_bid, checkpoint_history, owner_address) do
    cond do
      onchain_bid.exited_block > 0 ->
        nil

      snapshot.block_number >= snapshot.end_block and not snapshot.is_graduated ->
        %{
          type: :exit_bid,
          prepared:
            build_exit_prepared!(snapshot, onchain_bid_id, %{type: :exit_bid}, owner_address)
        }

      snapshot.block_number >= snapshot.end_block and
          onchain_bid.max_price_q96 > snapshot.checkpoint.clearing_price_q96 ->
        %{
          type: :exit_bid,
          prepared:
            build_exit_prepared!(snapshot, onchain_bid_id, %{type: :exit_bid}, owner_address)
        }

      snapshot.is_graduated and
          onchain_bid.max_price_q96 <= snapshot.checkpoint.clearing_price_q96 ->
        case partial_exit_hints(snapshot, onchain_bid, checkpoint_history) do
          {:ok, %{last_fully_filled_checkpoint_block: _, outbid_block: _} = hints} ->
            %{
              type: :exit_partially_filled_bid,
              last_fully_filled_checkpoint_block: hints.last_fully_filled_checkpoint_block,
              outbid_block: hints.outbid_block,
              prepared:
                build_exit_prepared!(
                  snapshot,
                  onchain_bid_id,
                  %{
                    type: :exit_partially_filled_bid,
                    last_fully_filled_checkpoint_block: hints.last_fully_filled_checkpoint_block,
                    outbid_block: hints.outbid_block
                  },
                  owner_address
                )
            }

          {:error, _reason} ->
            nil
        end

      true ->
        nil
    end
  end

  defp claim_action(snapshot, onchain_bid_id, onchain_bid, owner_address) do
    if onchain_bid.exited_block > 0 and onchain_bid.tokens_filled_units > 0 and
         snapshot.block_number >= snapshot.claim_block do
      %{prepared: build_claim_prepared!(snapshot, onchain_bid_id, owner_address)}
    else
      nil
    end
  end

  defp partial_exit_hints(snapshot, onchain_bid, checkpoint_history) do
    checkpoints =
      checkpoint_history
      |> maybe_append_current_checkpoint(snapshot)
      |> Enum.filter(&(&1.checkpoint_block_number >= onchain_bid.start_block))

    first_checkpoint_at_or_above =
      Enum.find_index(checkpoints, &(&1.clearing_price_q96 >= onchain_bid.max_price_q96))

    with index when is_integer(index) and index > 0 <- first_checkpoint_at_or_above,
         last_fully_filled <- Enum.at(checkpoints, index - 1),
         true <- last_fully_filled.clearing_price_q96 < onchain_bid.max_price_q96 do
      outbid_block =
        case Enum.find(checkpoints, &(&1.clearing_price_q96 > onchain_bid.max_price_q96)) do
          nil ->
            if snapshot.block_number >= snapshot.end_block and
                 snapshot.checkpoint.clearing_price_q96 == onchain_bid.max_price_q96 do
              0
            else
              nil
            end

          checkpoint ->
            checkpoint.checkpoint_block_number
        end

      if is_integer(outbid_block) do
        {:ok,
         %{
           last_fully_filled_checkpoint_block: last_fully_filled.checkpoint_block_number,
           outbid_block: outbid_block
         }}
      else
        {:error, :bid_not_exitable}
      end
    else
      _ -> {:error, :invalid_partial_exit_hints}
    end
  end

  defp maybe_append_current_checkpoint(checkpoint_history, snapshot) do
    current =
      %{
        checkpoint_block_number: snapshot.block_number,
        block_number: snapshot.block_number,
        clearing_price_q96: snapshot.checkpoint.clearing_price_q96,
        cumulative_mps: snapshot.checkpoint.cumulative_mps
      }

    checkpoint_history
    |> Enum.reject(&(&1.checkpoint_block_number == current.checkpoint_block_number))
    |> Kernel.++([current])
    |> Enum.sort_by(& &1.checkpoint_block_number)
  end

  defp find_bid_submitted_event(logs, auction_address, owner_address, amount_wei, max_price_q96) do
    expected_owner = normalize_address(owner_address)

    events =
      logs
      |> Enum.filter(&(&1.address == normalize_address(auction_address)))
      |> Enum.reduce([], fn log, acc ->
        case Abi.decode_bid_submitted_log(log) do
          {:ok, %{owner_address: ^expected_owner} = event} -> [event | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    case Enum.find(events, &(&1.amount_wei == amount_wei and &1.max_price_q96 == max_price_q96)) do
      nil -> {:error, :bid_submission_event_not_found}
      event -> {:ok, event}
    end
  end

  defp find_bid_exited_event(logs, auction_address, owner_address, onchain_bid_id) do
    expected_owner = normalize_address(owner_address)

    logs
    |> Enum.filter(&(&1.address == normalize_address(auction_address)))
    |> Enum.reduce_while({:error, :bid_exit_event_not_found}, fn log, _acc ->
      case Abi.decode_bid_exited_log(log) do
        {:ok, event} ->
          if event.owner_address == expected_owner and event.onchain_bid_id == onchain_bid_id do
            {:halt, {:ok, event}}
          else
            {:cont, {:error, :bid_exit_event_not_found}}
          end

        _ ->
          {:cont, {:error, :bid_exit_event_not_found}}
      end
    end)
  end

  defp find_tokens_claimed_event(logs, auction_address, owner_address, onchain_bid_id) do
    expected_owner = normalize_address(owner_address)

    logs
    |> Enum.filter(&(&1.address == normalize_address(auction_address)))
    |> Enum.reduce_while({:error, :tokens_claimed_event_not_found}, fn log, _acc ->
      case Abi.decode_tokens_claimed_log(log) do
        {:ok, event} ->
          if event.owner_address == expected_owner and event.onchain_bid_id == onchain_bid_id do
            {:halt, {:ok, event}}
          else
            {:cont, {:error, :tokens_claimed_event_not_found}}
          end

        _ ->
          {:cont, {:error, :tokens_claimed_event_not_found}}
      end
    end)
  end

  defp ensure_successful_receipt(nil), do: {:error, :transaction_pending}

  defp ensure_successful_receipt(%{status: 1}), do: :ok
  defp ensure_successful_receipt(%{status: 0}), do: {:error, :transaction_failed}
  defp ensure_successful_receipt(_receipt), do: {:error, :invalid_transaction_receipt}

  defp ensure_receipt_target(%{to: to}, expected_auction_address) do
    if normalize_address(to) == normalize_address(expected_auction_address),
      do: :ok,
      else: {:error, :transaction_target_mismatch}
  end

  defp ensure_receipt_sender(%{from: from}, expected_owner_address) do
    if normalize_address(from) == normalize_address(expected_owner_address),
      do: :ok,
      else: {:error, :transaction_sender_mismatch}
  end

  defp ensure_bid_owner(%{owner_address: owner_address}, expected_owner_address) do
    if normalize_address(owner_address) == normalize_address(expected_owner_address),
      do: :ok,
      else: {:error, :bid_owner_mismatch}
  end

  defp parse_onchain_bid_id(value) when is_binary(value) and value != "" do
    case Integer.parse(value) do
      {bid_id, ""} -> {:ok, bid_id}
      _ -> {:error, :invalid_onchain_bid_id}
    end
  end

  defp parse_onchain_bid_id(_value), do: {:error, :invalid_onchain_bid_id}

  defp build_exit_tx_request!(snapshot, onchain_bid_id, action) do
    {:ok, request} =
      build_exit_tx_request(
        %{chain_id: snapshot.chain_id, auction_address: snapshot.auction_address},
        onchain_bid_id,
        action
      )

    request
  end

  defp build_claim_tx_request!(snapshot, onchain_bid_id) do
    {:ok, request} =
      build_claim_tx_request(
        %{chain_id: snapshot.chain_id, auction_address: snapshot.auction_address},
        onchain_bid_id
      )

    request
  end

  defp build_exit_prepared!(snapshot, onchain_bid_id, action, owner_address) do
    request = build_exit_tx_request!(snapshot, onchain_bid_id, action)

    params =
      action
      |> Map.drop([:type])
      |> Map.put(:onchain_bid_id, Integer.to_string(onchain_bid_id))

    {:ok, prepared} =
      ActionParams.prepare_tx_request(
        request,
        "auction",
        Atom.to_string(action.type),
        params,
        expected_signer: owner_address
      )

    prepared
  end

  defp build_claim_prepared!(snapshot, onchain_bid_id, owner_address) do
    request = build_claim_tx_request!(snapshot, onchain_bid_id)

    {:ok, prepared} =
      ActionParams.prepare_tx_request(
        request,
        "auction",
        "claim_bid",
        %{onchain_bid_id: Integer.to_string(onchain_bid_id)},
        expected_signer: owner_address
      )

    prepared
  end

  defp to_hex_quantity(value) when is_integer(value) and value >= 0 do
    "0x" <> Integer.to_string(value, 16)
  end

  defp normalize_hash(hash) when is_binary(hash), do: String.downcase(String.trim(hash))
  defp normalize_hash(hash), do: hash

  defp normalize_address(address) when is_binary(address),
    do: String.downcase(String.trim(address))

  defp normalize_address(_address), do: nil
end
