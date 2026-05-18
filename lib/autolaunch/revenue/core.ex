defmodule Autolaunch.Revenue.Core do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts.ActionParams
  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.Revenue.Abi
  alias Autolaunch.Revenue.SubjectActionRegistration

  @usdc_decimals 6
  @token_decimals 18
  @eligible_share_proposed_topic0 "0xdea1cf6e658a0d5758b71519980315f6a1dd1377c7de69e48adc4a4f318a1283"
  @eligible_share_cancelled_topic0 "0x10cb96b400282a7ceaa5f8861808ae2919fd8925eb8ee66c751afc59e7c8fb5d"
  @eligible_share_activated_topic0 "0x58af83b8600b3af6bd5ced17057404f562a686f59299b9e65067534837eb13f5"

  def get_subject(subject_id, current_human \\ nil) do
    with {:ok, %{subject: subject}} <- subject_scope(subject_id, current_human) do
      {:ok, subject}
    end
  end

  def subject_scope(subject_id, current_human \\ nil) do
    with {:ok, normalized_subject_id} <- normalize_subject_id(subject_id),
         {:ok, job} <- fetch_subject_job(normalized_subject_id),
         owner_address = primary_wallet_address(current_human),
         {:ok, subject} <-
           Autolaunch.LocalCache.fetch(
             subject_cache_key(job, normalized_subject_id, owner_address),
             15,
             fn ->
               build_subject(job, normalized_subject_id, owner_address)
             end
           ) do
      {:ok, %{subject: subject, job: job}}
    end
  rescue
    _ -> unavailable_subject_data()
  end

  def subject_state(subject_id, current_human \\ nil) do
    with {:ok, subject} <- get_subject(subject_id, current_human) do
      {:ok, %{subject: subject}}
    end
  end

  def subject_wallet_position(subject_id, wallet_address) do
    with {:ok, normalized_subject_id} <- normalize_subject_id(subject_id),
         {:ok, job} <- fetch_subject_job(normalized_subject_id),
         {:ok, normalized_wallet} <- normalize_required_address(wallet_address) do
      subject_wallet_position_from_job(job, normalized_wallet)
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> unavailable_subject_data()
  end

  def subject_wallet_positions(subject_id, wallet_addresses) do
    with {:ok, normalized_subject_id} <- normalize_subject_id(subject_id),
         {:ok, job} <- fetch_subject_job(normalized_subject_id),
         {:ok, addresses} <- normalize_address_list(wallet_addresses) do
      Autolaunch.LocalCache.fetch(
        wallet_positions_cache_key(job, normalized_subject_id, addresses),
        10,
        fn ->
          build_wallet_positions(job, addresses)
        end
      )
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> unavailable_subject_data()
  end

  def subject_portfolio_state(subject_id, wallet_addresses, current_human \\ nil) do
    with {:ok, addresses} <- normalize_address_list(wallet_addresses),
         {:ok, %{subject: subject, job: job}} <- subject_scope(subject_id, current_human),
         {:ok, position} <- build_wallet_positions(job, addresses) do
      {:ok, %{subject: subject, position: position}}
    end
  end

  def subject_obligation_metrics(subject_id, staker_addresses) do
    with {:ok, normalized_subject_id} <- normalize_subject_id(subject_id),
         {:ok, job} <- fetch_subject_job(normalized_subject_id),
         {:ok, addresses} <- normalize_address_list(staker_addresses) do
      Autolaunch.LocalCache.fetch(
        obligation_metrics_cache_key(job, normalized_subject_id, addresses),
        15,
        fn ->
          build_subject_obligation_metrics(job, normalized_subject_id, addresses)
        end
      )
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> unavailable_subject_data()
  end

  def get_ingress(subject_id, current_human \\ nil) do
    with {:ok, subject} <- get_subject(subject_id, current_human) do
      {:ok,
       %{
         subject_id: subject.subject_id,
         chain_id: subject.chain_id,
         default_ingress_address: subject.default_ingress_address,
         can_manage_ingress: subject.can_manage_ingress,
         accounts: subject.ingress_accounts
       }}
    end
  end

  def ingress_state(subject_id, current_human \\ nil), do: get_ingress(subject_id, current_human)

  def accounting_tags(subject_id, attrs, current_human \\ nil) do
    with {:ok, subject} <- get_subject(subject_id, current_human),
         {:ok, from_block} <-
           required_non_negative_int(
             attrs,
             "from_block",
             :from_block_required,
             :invalid_from_block
           ),
         {:ok, cursor} <- optional_non_negative_int(attrs, "cursor", 0, :invalid_cursor),
         {:ok, limit} <- optional_limit(attrs, "limit", 100) do
      read_accounting_tags(subject, from_block, cursor, limit)
    end
  end

  def stake(subject_id, attrs, current_human),
    do: write_action(:stake, subject_id, attrs, current_human)

  def unstake(subject_id, attrs, current_human),
    do: write_action(:unstake, subject_id, attrs, current_human)

  def claim_usdc(subject_id, attrs, current_human),
    do: write_action(:claim_usdc, subject_id, attrs, current_human)

  def sweep_ingress(subject_id, ingress_address, attrs, current_human) do
    with {:ok, subject} <- get_subject(subject_id, current_human),
         {:ok, wallet_address} <- required_wallet(current_human),
         true <- subject.can_manage_ingress || {:error, :forbidden},
         {:ok, ingress} <- validate_ingress(subject, ingress_address),
         {:ok, tx_hash} <- tx_hash_param(attrs) do
      case tx_hash do
        nil ->
          {:ok,
           %{
             subject: subject,
             prepared:
               prepare_subject_action!(
                 :sweep_ingress,
                 subject,
                 wallet_address,
                 chain_id: subject.chain_id,
                 to: ingress.address,
                 value_hex: "0x0",
                 data: Abi.encode_sweep_usdc(),
                 params: %{ingress_address: ingress.address}
               )
           }}

        tx_hash ->
          register_action(
            :sweep_ingress,
            subject,
            wallet_address,
            attrs,
            tx_hash,
            ingress.address,
            current_human
          )
      end
    else
      {:error, _} = error -> error
      false -> {:error, :not_found}
    end
  end

  defp write_action(action, subject_id, attrs, current_human) do
    with {:ok, subject} <- get_subject(subject_id, current_human),
         {:ok, wallet_address} <- required_wallet(current_human),
         {:ok, tx_hash} <- tx_hash_param(attrs) do
      case tx_hash do
        nil ->
          build_write_request(action, subject, wallet_address, attrs)

        tx_hash ->
          register_action(
            action,
            subject,
            wallet_address,
            attrs,
            tx_hash,
            subject.splitter_address,
            current_human
          )
      end
    end
  end

  defp build_write_request(action, subject, wallet_address, attrs)
       when action in [:stake, :unstake] do
    with {:ok, amount_wei} <- required_amount_wei(attrs),
         {:ok, receiver} <- amount_action_receiver(action, attrs, wallet_address) do
      {:ok,
       %{
         subject: subject,
         prepared:
           prepare_subject_action!(
             action,
             subject,
             wallet_address,
             chain_id: subject.chain_id,
             to: subject.splitter_address,
             value_hex: "0x0",
             data: amount_action_call(action, amount_wei, receiver),
             params: amount_action_params(action, amount_wei, receiver)
           )
       }}
    end
  end

  defp build_write_request(:claim_usdc, subject, wallet_address, _attrs) do
    {:ok,
     %{
       subject: subject,
       prepared:
         prepare_subject_action!(
           :claim_usdc,
           subject,
           wallet_address,
           chain_id: subject.chain_id,
           to: subject.splitter_address,
           value_hex: "0x0",
           data: single_recipient_action_call(:claim_usdc, wallet_address)
         )
     }}
  end

  defp build_write_request(:sweep_ingress, subject, wallet_address, _attrs) do
    {:ok,
     %{
       subject: subject,
       prepared:
         prepare_subject_action!(
           :sweep_ingress,
           subject,
           wallet_address,
           chain_id: subject.chain_id,
           to: subject.default_ingress_address,
           value_hex: "0x0",
           data: Abi.encode_sweep_usdc(),
           params: %{ingress_address: subject.default_ingress_address}
         )
     }}
  end

  defp register_action(
         action,
         subject,
         wallet_address,
         attrs,
         tx_hash,
         expected_to,
         current_human
       ) do
    with {:ok, registration_attrs} <-
           registration_attrs(action, subject, wallet_address, attrs, tx_hash, expected_to),
         {:ok, registration} <- existing_registration(registration_attrs) do
      case registration do
        nil ->
          validate_and_create_registration(
            action,
            subject,
            wallet_address,
            attrs,
            tx_hash,
            expected_to,
            current_human,
            registration_attrs
          )

        %SubjectActionRegistration{} = registration ->
          register_action_with_registration(
            action,
            subject,
            wallet_address,
            attrs,
            tx_hash,
            expected_to,
            current_human,
            registration,
            registration_attrs
          )
      end
    end
  end

  defp validate_and_create_registration(
         action,
         subject,
         wallet_address,
         attrs,
         tx_hash,
         expected_to,
         current_human,
         registration_attrs
       ) do
    with {:ok, receipt_state} <-
           validate_registration_submission(
             action,
             subject,
             wallet_address,
             attrs,
             tx_hash,
             expected_to,
             registration_attrs
           ),
         {:ok, registration} <- insert_registration(registration_attrs),
         {:ok, result} <-
           finalize_registration(registration, receipt_state, subject, current_human) do
      {:ok, result}
    end
  end

  defp register_action_with_registration(
         action,
         subject,
         wallet_address,
         attrs,
         tx_hash,
         expected_to,
         current_human,
         registration,
         registration_attrs
       ) do
    cond do
      registration.status == "rejected" ->
        {:error, error_code_atom(registration.error_code) || :transaction_data_mismatch}

      registration.status == "confirmed" ->
        bump_subject_cache_epoch(subject.subject_id)

        with {:ok, refreshed} <- get_subject(subject.subject_id, current_human) do
          {:ok, %{subject: refreshed}}
        end

      true ->
        with {:ok, receipt_state} <-
               validate_registration_submission(
                 action,
                 subject,
                 wallet_address,
                 attrs,
                 tx_hash,
                 expected_to,
                 registration_attrs
               ),
             {:ok, result} <-
               finalize_registration(registration, receipt_state, subject, current_human) do
          {:ok, result}
        end
    end
  end

  defp registration_attrs(action, subject, wallet_address, attrs, tx_hash, expected_to) do
    base_attrs = %{
      subject_id: subject.subject_id,
      action: action_name(action),
      owner_address: wallet_address,
      chain_id: subject.chain_id,
      tx_hash: tx_hash,
      status: "pending"
    }

    case action do
      a when a in [:stake, :unstake] ->
        with {:ok, amount_wei} <- required_amount_wei(attrs) do
          {:ok, Map.put(base_attrs, :amount, Integer.to_string(amount_wei))}
        end

      :sweep_ingress ->
        {:ok, Map.put(base_attrs, :ingress_address, expected_to)}

      _ ->
        {:ok, base_attrs}
    end
  end

  defp existing_registration(registration_attrs) do
    case Repo.get_by(SubjectActionRegistration, tx_hash: registration_attrs.tx_hash) do
      nil ->
        {:ok, nil}

      %SubjectActionRegistration{} = registration ->
        if registration_scope_matches?(registration, registration_attrs) do
          {:ok, registration}
        else
          {:error, :transaction_hash_reused}
        end
    end
  end

  defp registration_scope_matches?(registration, attrs) do
    normalize_address(registration.subject_id) == normalize_address(attrs.subject_id) and
      registration.action == attrs.action and
      normalize_address(registration.owner_address) == normalize_address(attrs.owner_address) and
      registration.chain_id == attrs.chain_id and
      normalize_address(registration.ingress_address) ==
        normalize_address(Map.get(attrs, :ingress_address))
  end

  defp finalize_registration(registration, :pending, _subject, _current_human) do
    with :ok <-
           update_registration(registration, %{
             status: "pending",
             error_code: nil,
             error_message: nil
           }) do
      {:error, :transaction_pending}
    end
  end

  defp finalize_registration(
         registration,
         {:confirmed, block_number},
         subject,
         current_human
       ) do
    with :ok <-
           update_registration(registration, %{
             status: "confirmed",
             block_number: block_number,
             error_code: nil,
             error_message: nil
           }),
         :ok <- bump_subject_cache_epoch(subject.subject_id),
         {:ok, refreshed} <- get_subject(subject.subject_id, current_human) do
      {:ok, %{subject: refreshed}}
    end
  end

  defp finalize_registration(registration, {:failed, error_code}, _subject, _current_human) do
    with :ok <-
           update_registration(registration, %{
             status: "rejected",
             error_code: Atom.to_string(error_code),
             error_message: default_error_message(error_code)
           }) do
      {:error, error_code}
    end
  end

  defp update_registration(%SubjectActionRegistration{} = registration, attrs) do
    registration
    |> SubjectActionRegistration.update_status_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, _registration} -> :ok
      {:error, reason} -> {:error, {:subject_action_registration_update_failed, reason}}
    end
  end

  defp validate_registration_submission(
         action,
         subject,
         wallet_address,
         attrs,
         tx_hash,
         expected_to,
         registration_attrs
       ) do
    with {:ok, receipt_state} <-
           fetch_receipt_state(subject.chain_id, tx_hash, wallet_address, expected_to),
         {:ok, tx} <- fetch_transaction(subject.chain_id, tx_hash),
         :ok <-
           validate_registered_action(
             action,
             subject,
             wallet_address,
             attrs,
             tx,
             expected_to,
             registration_attrs,
             receipt_state
           ) do
      {:ok, receipt_state}
    end
  end

  defp validate_registered_action(
         action,
         _subject,
         wallet_address,
         attrs,
         tx,
         expected_to,
         registration_attrs,
         _receipt_state
       )
       when action in [:stake, :unstake] do
    with {:ok, amount_wei} <- required_amount_wei(attrs),
         {:ok, expected_receiver} <- amount_action_receiver(action, attrs, wallet_address),
         :ok <- validate_tx_sender(tx, wallet_address),
         :ok <- validate_tx_target(tx, expected_to) do
      case Abi.decode_call_data(tx.input) do
        {:ok, %{action: ^action} = decoded} ->
          decoded_address_key = if action == :stake, do: :receiver, else: :recipient

          with :ok <-
                 validate_equal(
                   Map.get(decoded, :amount_wei),
                   amount_wei,
                   :transaction_data_mismatch
                 ),
               :ok <-
                 validate_equal(
                   normalize_address(Map.get(decoded, decoded_address_key)),
                   normalize_address(expected_receiver),
                   :transaction_data_mismatch
                 ),
               :ok <-
                 validate_equal(
                   Map.get(registration_attrs, :amount),
                   Integer.to_string(amount_wei),
                   :transaction_data_mismatch
                 ) do
            :ok
          end

        _ ->
          {:error, :transaction_data_mismatch}
      end
    end
  end

  defp validate_registered_action(
         :claim_usdc,
         _subject,
         wallet_address,
         _attrs,
         tx,
         expected_to,
         _registration_attrs,
         _receipt_state
       ) do
    with :ok <- validate_tx_sender(tx, wallet_address),
         :ok <- validate_tx_target(tx, expected_to) do
      case Abi.decode_call_data(tx.input) do
        {:ok, %{action: :claim_usdc, recipient: recipient}} ->
          validate_equal(
            normalize_address(recipient),
            normalize_address(wallet_address),
            :transaction_data_mismatch
          )

        _ ->
          {:error, :transaction_data_mismatch}
      end
    end
  end

  defp validate_registered_action(
         :sweep_ingress,
         _subject,
         wallet_address,
         _attrs,
         tx,
         expected_to,
         registration_attrs,
         _receipt_state
       ) do
    with :ok <- validate_tx_sender(tx, wallet_address),
         :ok <- validate_tx_target(tx, expected_to) do
      case Abi.decode_call_data(tx.input) do
        {:ok, %{action: :sweep_ingress}} ->
          validate_equal(
            normalize_address(Map.get(registration_attrs, :ingress_address)),
            normalize_address(expected_to),
            :transaction_data_mismatch
          )

        _ ->
          {:error, :transaction_data_mismatch}
      end
    end
  end

  defp validate_registered_action(
         _action,
         _subject,
         _wallet_address,
         _attrs,
         _tx,
         _expected_to,
         _registration_attrs,
         _receipt_state
       ),
       do: {:error, :transaction_data_mismatch}

  defp insert_registration(registration_attrs) do
    %SubjectActionRegistration{}
    |> SubjectActionRegistration.create_changeset(registration_attrs)
    |> Repo.insert()
  end

  defp read_accounting_tags(subject, from_block, cursor, limit) do
    with {:ok, ingress_tags} <- read_ingress_accounting_tags(subject, from_block),
         {:ok, direct_tags} <- read_direct_accounting_tags(subject, from_block) do
      sorted_tags = Enum.sort_by(ingress_tags ++ direct_tags, &accounting_tag_sort_key/1)

      {page, remaining} =
        sorted_tags
        |> Enum.drop(cursor)
        |> Enum.split(limit)

      {:ok,
       %{
         subject_id: subject.subject_id,
         chain_id: subject.chain_id,
         from_block: from_block,
         cursor: cursor,
         limit: limit,
         next_cursor: cursor + length(page),
         has_more: remaining != [],
         accounting_tags: Enum.map(page, &format_accounting_tag/1)
       }}
    end
  end

  defp read_ingress_accounting_tags(subject, from_block) do
    addresses = Enum.map(subject.ingress_accounts, & &1.address)

    if addresses == [] do
      {:ok, []}
    else
      subject.chain_id
      |> Rpc.get_logs(%{
        "address" => addresses,
        "fromBlock" => encode_block_number(from_block),
        "toBlock" => "latest",
        "topics" => [Abi.accounting_tag_recorded_topic0()]
      })
      |> case do
        {:ok, logs} -> decode_accounting_tag_logs(logs)
        {:error, _reason} -> {:error, :accounting_tags_unavailable}
      end
    end
  end

  defp read_direct_accounting_tags(subject, from_block) do
    subject.chain_id
    |> Rpc.get_logs(%{
      "address" => subject.splitter_address,
      "fromBlock" => encode_block_number(from_block),
      "toBlock" => "latest",
      "topics" => [Abi.usdc_revenue_deposited_topic0(), Abi.direct_deposit_source_kind_topic()]
    })
    |> case do
      {:ok, logs} -> decode_direct_revenue_logs(logs)
      {:error, _reason} -> {:error, :accounting_tags_unavailable}
    end
  end

  defp decode_accounting_tag_logs(logs) do
    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, acc} ->
      case Abi.decode_accounting_tag_log(log) do
        {:ok, tag} -> {:cont, {:ok, [tag | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_accounting_tag_log}}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.reverse(tags)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_direct_revenue_logs(logs) do
    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, acc} ->
      case Abi.decode_direct_revenue_log(log) do
        {:ok, tag} -> {:cont, {:ok, [tag | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_accounting_tag_log}}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.reverse(tags)}
      {:error, _reason} = error -> error
    end
  end

  defp accounting_tag_sort_key(tag) do
    {tag.block_number, tag.source, tag.ingress_address || tag.splitter_address,
     tag.tag_index || tag.log_index || 0}
  end

  defp validate_tx_sender(%{from: from}, wallet_address) do
    if normalize_address(from) == normalize_address(wallet_address),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp validate_tx_sender(_tx, _wallet_address), do: {:error, :forbidden}

  defp validate_tx_target(%{to: to}, expected_to) do
    if normalize_address(to) == normalize_address(expected_to),
      do: :ok,
      else: {:error, :transaction_target_mismatch}
  end

  defp validate_tx_target(_tx, _expected_to), do: {:error, :transaction_target_mismatch}

  defp validate_equal(left, right, error_code) do
    if left == right, do: :ok, else: {:error, error_code}
  end

  defp required_amount_wei(attrs) do
    parse_token_amount(Map.get(attrs, "amount"))
  end

  defp amount_action_receiver(:stake, attrs, wallet_address),
    do: optional_receiver(attrs, wallet_address)

  defp amount_action_receiver(:unstake, _attrs, wallet_address), do: {:ok, wallet_address}

  defp optional_receiver(attrs, default_receiver) do
    case optional_text(Map.get(attrs, "receiver")) do
      nil -> {:ok, default_receiver}
      receiver -> normalize_required_address(receiver)
    end
  end

  defp optional_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp optional_text(_value), do: nil

  defp amount_action_call(:stake, amount_wei, receiver),
    do: Abi.encode_stake(amount_wei, receiver)

  defp amount_action_call(:unstake, amount_wei, recipient),
    do: Abi.encode_unstake(amount_wei, recipient)

  defp amount_action_params(:stake, amount_wei, receiver),
    do: %{amount: Integer.to_string(amount_wei), receiver: receiver}

  defp amount_action_params(:unstake, amount_wei, _recipient),
    do: %{amount: Integer.to_string(amount_wei)}

  defp single_recipient_action_call(:claim_usdc, wallet_address),
    do: Abi.encode_claim_usdc(wallet_address)

  defp action_name(:stake), do: "stake"
  defp action_name(:unstake), do: "unstake"
  defp action_name(:claim_usdc), do: "claim_usdc"
  defp action_name(:sweep_ingress), do: "sweep_ingress"

  defp validate_receipt_state(chain_id, tx_hash, wallet_address, expected_to) do
    case Rpc.tx_receipt(chain_id, tx_hash) do
      {:ok, nil} ->
        {:ok, :pending}

      {:ok, receipt} when is_map(receipt) ->
        with :ok <- validate_receipt_hash(receipt, tx_hash),
             :ok <- validate_receipt_sender(receipt, wallet_address),
             :ok <- validate_receipt_target(receipt, expected_to) do
          {:ok, receipt_status(receipt)}
        end

      {:error, _reason} ->
        {:ok, :pending}

      _ ->
        {:ok, :pending}
    end
  end

  defp fetch_transaction(chain_id, tx_hash) do
    case Rpc.tx_by_hash(chain_id, tx_hash) do
      {:ok, nil} -> {:error, :transaction_data_mismatch}
      {:ok, tx} when is_map(tx) -> {:ok, tx}
      {:error, _} -> {:error, :transaction_data_mismatch}
      _ -> {:error, :transaction_data_mismatch}
    end
  end

  defp fetch_receipt_state(chain_id, tx_hash, wallet_address, expected_to) do
    validate_receipt_state(chain_id, tx_hash, wallet_address, expected_to)
  end

  defp receipt_status(%{status: 1, block_number: block_number}), do: {:confirmed, block_number}
  defp receipt_status(%{status: 1}), do: {:confirmed, nil}
  defp receipt_status(%{status: 0}), do: {:failed, :transaction_failed}
  defp receipt_status(_receipt), do: :pending

  defp validate_receipt_hash(%{transaction_hash: receipt_tx_hash}, tx_hash) do
    validate_equal(
      normalize_hash(receipt_tx_hash),
      normalize_hash(tx_hash),
      :transaction_data_mismatch
    )
  end

  defp validate_receipt_hash(_receipt, _tx_hash), do: {:error, :transaction_data_mismatch}

  defp validate_receipt_sender(%{from: from}, wallet_address),
    do: validate_tx_sender(%{from: from}, wallet_address)

  defp validate_receipt_sender(_receipt, _wallet_address), do: {:error, :forbidden}

  defp validate_receipt_target(%{to: to}, expected_to),
    do: validate_tx_target(%{to: to}, expected_to)

  defp validate_receipt_target(_receipt, _expected_to), do: {:error, :transaction_target_mismatch}

  defp error_code_atom(nil), do: nil
  defp error_code_atom(code) when is_atom(code), do: code
  defp error_code_atom("transaction_failed"), do: :transaction_failed
  defp error_code_atom("transaction_pending"), do: :transaction_pending
  defp error_code_atom("transaction_data_mismatch"), do: :transaction_data_mismatch
  defp error_code_atom("transaction_target_mismatch"), do: :transaction_target_mismatch
  defp error_code_atom("transaction_hash_reused"), do: :transaction_hash_reused
  defp error_code_atom("forbidden"), do: :forbidden
  defp error_code_atom(_code), do: nil

  defp default_error_message(:transaction_failed), do: "Transaction failed onchain"

  defp default_error_message(:transaction_pending),
    do: "Transaction is still pending confirmation"

  defp default_error_message(:transaction_data_mismatch),
    do: "Transaction input does not match this subject action"

  defp default_error_message(:transaction_target_mismatch),
    do: "Transaction target does not match this subject"

  defp default_error_message(:transaction_hash_reused),
    do: "Transaction hash has already been registered"

  defp default_error_message(:forbidden), do: "Transaction sender does not match this wallet"
  defp default_error_message(_), do: "Transaction registration failed"

  defp build_subject_obligation_metrics(job, subject_id, addresses) do
    exact_total_accrued_obligations_raw =
      Enum.reduce(addresses, 0, fn address, acc ->
        acc +
          call_uint(
            job.chain_id,
            job.revenue_share_splitter_address,
            Abi.encode_address_call(:preview_claimable_stake_token, address)
          )
      end)

    materialized_outstanding_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:unclaimed_stake_token_liability)
      )

    available_reward_inventory_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:available_stake_token_reward_inventory)
      )

    total_claimed_so_far_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:total_claimed_stake_token)
      )

    {:ok,
     %{
       subject_id: subject_id,
       chain_id: job.chain_id,
       splitter_address: job.revenue_share_splitter_address,
       staker_count: length(addresses),
       exact_total_accrued_obligations_raw: exact_total_accrued_obligations_raw,
       exact_total_accrued_obligations:
         format_units(exact_total_accrued_obligations_raw, @token_decimals),
       materialized_outstanding_raw: materialized_outstanding_raw,
       materialized_outstanding: format_units(materialized_outstanding_raw, @token_decimals),
       available_reward_inventory_raw: available_reward_inventory_raw,
       available_reward_inventory: format_units(available_reward_inventory_raw, @token_decimals),
       total_claimed_so_far_raw: total_claimed_so_far_raw,
       total_claimed_so_far: format_units(total_claimed_so_far_raw, @token_decimals),
       accrued_but_unsynced_raw:
         positive_difference(
           exact_total_accrued_obligations_raw,
           materialized_outstanding_raw
         ),
       accrued_but_unsynced:
         format_units(
           positive_difference(
             exact_total_accrued_obligations_raw,
             materialized_outstanding_raw
           ),
           @token_decimals
         ),
       funding_gap_raw:
         positive_difference(
           exact_total_accrued_obligations_raw,
           available_reward_inventory_raw
         ),
       funding_gap:
         format_units(
           positive_difference(
             exact_total_accrued_obligations_raw,
             available_reward_inventory_raw
           ),
           @token_decimals
         )
     }}
  end

  defp fetch_subject_job(subject_id) do
    case launch_chain_id() do
      {:ok, active_chain_id} ->
        case Repo.one(
               from job in Job,
                 where:
                   job.subject_id == ^subject_id and job.status == "ready" and
                     job.chain_id == ^active_chain_id,
                 order_by: [desc: job.updated_at],
                 limit: 1
             ) do
          %Job{} = job -> {:ok, job}
          nil -> missing_subject()
        end

      {:error, _} ->
        missing_subject()
    end
  end

  defp build_subject(job, subject_id, owner_address) do
    ingress_accounts = load_ingress_accounts(job, subject_id)
    can_manage = owner_address && can_manage_subject?(job, subject_id, owner_address)
    share_change_history = load_share_change_history(job)

    total_staked =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:total_staked)
      )

    treasury_residual_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:treasury_residual_usdc)
      )

    treasury_reserved_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:treasury_reserved_usdc)
      )

    protocol_reserve_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:protocol_reserve_usdc)
      )

    eligible_revenue_share_bps =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:eligible_revenue_share_bps)
      )

    pending_eligible_revenue_share_bps =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:pending_eligible_revenue_share_bps)
      )

    pending_eligible_revenue_share_eta_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:pending_eligible_revenue_share_eta)
      )

    eligible_revenue_share_cooldown_end_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:eligible_revenue_share_cooldown_end)
      )

    total_usdc_received =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:total_usdc_received)
      )

    direct_deposit_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:direct_deposit_usdc)
      )

    verified_ingress_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:verified_ingress_usdc)
      )

    regent_skim_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:regent_skim_usdc)
      )

    staker_eligible_inflow_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:staker_eligible_inflow_usdc)
      )

    treasury_reserved_inflow_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:treasury_reserved_inflow_usdc)
      )

    undistributed_dust_usdc =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:undistributed_dust_usdc)
      )

    wallet_stake_balance_raw =
      owner_address &&
        call_uint(
          job.chain_id,
          job.revenue_share_splitter_address,
          Abi.encode_address_call(:staked_balance, owner_address)
        )

    wallet_token_balance_raw =
      owner_address &&
        call_uint(
          job.chain_id,
          job.token_address,
          Abi.encode_address_call(:balance_of, owner_address)
        )

    claimable_usdc_raw =
      owner_address &&
        call_uint(
          job.chain_id,
          job.revenue_share_splitter_address,
          Abi.encode_address_call(:preview_claimable_usdc, owner_address)
        )

    claimable_stake_token_raw =
      owner_address &&
        call_uint(
          job.chain_id,
          job.revenue_share_splitter_address,
          Abi.encode_address_call(:preview_claimable_stake_token, owner_address)
        )

    funded_claimable_stake_token_raw =
      owner_address &&
        call_uint(
          job.chain_id,
          job.revenue_share_splitter_address,
          Abi.encode_address_call(:preview_funded_claimable_stake_token, owner_address)
        )

    materialized_outstanding_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:unclaimed_stake_token_liability)
      )

    available_reward_inventory_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:available_stake_token_reward_inventory)
      )

    total_claimed_so_far_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_no_args(:total_claimed_stake_token)
      )

    default_ingress_address =
      Map.get(ingress_accounts, :default_address) || job.default_ingress_address

    {:ok,
     %{
       subject_id: subject_id,
       chain_id: job.chain_id,
       chain_label: chain_label(job.chain_id),
       token_address: job.token_address,
       strategy_address: job.strategy_address,
       subject_registry_address: job.subject_registry_address,
       splitter_address: job.revenue_share_splitter_address,
       default_ingress_address: default_ingress_address,
       ingress_accounts: ingress_accounts.accounts,
       total_staked_raw: total_staked,
       total_staked: format_units(total_staked, @token_decimals),
       eligible_revenue_share_bps: eligible_revenue_share_bps,
       eligible_revenue_share_percent: bps_to_percent_string(eligible_revenue_share_bps),
       pending_eligible_revenue_share_bps: zero_to_nil(pending_eligible_revenue_share_bps),
       pending_eligible_revenue_share_percent: percent_or_nil(pending_eligible_revenue_share_bps),
       pending_eligible_revenue_share_eta_raw:
         zero_to_nil(pending_eligible_revenue_share_eta_raw),
       pending_eligible_revenue_share_eta:
         format_unix_timestamp(zero_to_nil(pending_eligible_revenue_share_eta_raw)),
       eligible_revenue_share_cooldown_end_raw:
         zero_to_nil(eligible_revenue_share_cooldown_end_raw),
       eligible_revenue_share_cooldown_end:
         format_unix_timestamp(zero_to_nil(eligible_revenue_share_cooldown_end_raw)),
       total_usdc_received_raw: total_usdc_received,
       total_usdc_received: format_units(total_usdc_received, @usdc_decimals),
       direct_deposit_usdc_raw: direct_deposit_usdc,
       direct_deposit_usdc: format_units(direct_deposit_usdc, @usdc_decimals),
       verified_ingress_usdc_raw: verified_ingress_usdc,
       verified_ingress_usdc: format_units(verified_ingress_usdc, @usdc_decimals),
       regent_skim_usdc_raw: regent_skim_usdc,
       regent_skim_usdc: format_units(regent_skim_usdc, @usdc_decimals),
       staker_eligible_inflow_usdc_raw: staker_eligible_inflow_usdc,
       staker_eligible_inflow_usdc: format_units(staker_eligible_inflow_usdc, @usdc_decimals),
       treasury_reserved_inflow_usdc_raw: treasury_reserved_inflow_usdc,
       treasury_reserved_inflow_usdc: format_units(treasury_reserved_inflow_usdc, @usdc_decimals),
       treasury_residual_usdc_raw: treasury_residual_usdc,
       treasury_residual_usdc: format_units(treasury_residual_usdc, @usdc_decimals),
       treasury_reserved_usdc_raw: treasury_reserved_usdc,
       treasury_reserved_usdc: format_units(treasury_reserved_usdc, @usdc_decimals),
       protocol_reserve_usdc_raw: protocol_reserve_usdc,
       protocol_reserve_usdc: format_units(protocol_reserve_usdc, @usdc_decimals),
       undistributed_dust_usdc_raw: undistributed_dust_usdc,
       undistributed_dust_usdc: format_units(undistributed_dust_usdc, @usdc_decimals),
       recognized_revenue_proof:
         recognized_revenue_proof(job, default_ingress_address, total_usdc_received),
       share_change_history: share_change_history,
       wallet_address: owner_address,
       wallet_stake_balance_raw: wallet_stake_balance_raw,
       wallet_stake_balance:
         owner_address && format_units(wallet_stake_balance_raw, @token_decimals),
       wallet_token_balance_raw: wallet_token_balance_raw,
       wallet_token_balance:
         owner_address && format_units(wallet_token_balance_raw, @token_decimals),
       claimable_usdc_raw: claimable_usdc_raw,
       claimable_usdc: owner_address && format_units(claimable_usdc_raw, @usdc_decimals),
       claimable_stake_token_raw: claimable_stake_token_raw,
       claimable_stake_token:
         owner_address && format_units(claimable_stake_token_raw, @token_decimals),
       funded_claimable_stake_token_raw: funded_claimable_stake_token_raw,
       funded_claimable_stake_token:
         owner_address && format_units(funded_claimable_stake_token_raw, @token_decimals),
       materialized_outstanding_raw: materialized_outstanding_raw,
       materialized_outstanding: format_units(materialized_outstanding_raw, @token_decimals),
       available_reward_inventory_raw: available_reward_inventory_raw,
       available_reward_inventory: format_units(available_reward_inventory_raw, @token_decimals),
       total_claimed_so_far_raw: total_claimed_so_far_raw,
       total_claimed_so_far: format_units(total_claimed_so_far_raw, @token_decimals),
       can_manage_ingress: can_manage || false
     }}
  end

  defp recognized_revenue_proof(job, default_ingress_address, total_usdc_received) do
    block_number = current_block_number(job.chain_id)

    %{
      source: "onchain_splitter",
      chain_id: job.chain_id,
      ingress: default_ingress_address,
      revsplit: job.revenue_share_splitter_address,
      block_number: block_number,
      amount_raw: total_usdc_received,
      amount: format_units(total_usdc_received, @usdc_decimals),
      recipient_lane: "subject_revenue",
      status: if(is_integer(block_number), do: "fresh", else: "stale")
    }
  end

  defp current_block_number(chain_id) do
    case Rpc.block_number(chain_id) do
      {:ok, block_number} when is_integer(block_number) and block_number >= 0 -> block_number
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp subject_wallet_position_from_job(job, wallet_address) do
    wallet_stake_balance_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_address_call(:staked_balance, wallet_address)
      )

    claimable_usdc_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_address_call(:preview_claimable_usdc, wallet_address)
      )

    claimable_stake_token_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_address_call(:preview_claimable_stake_token, wallet_address)
      )

    funded_claimable_stake_token_raw =
      call_uint(
        job.chain_id,
        job.revenue_share_splitter_address,
        Abi.encode_address_call(:preview_funded_claimable_stake_token, wallet_address)
      )

    {:ok,
     %{
       wallet_address: wallet_address,
       wallet_stake_balance_raw: wallet_stake_balance_raw,
       wallet_stake_balance: format_units(wallet_stake_balance_raw, @token_decimals),
       claimable_usdc_raw: claimable_usdc_raw,
       claimable_usdc: format_units(claimable_usdc_raw, @usdc_decimals),
       claimable_stake_token_raw: claimable_stake_token_raw,
       claimable_stake_token: format_units(claimable_stake_token_raw, @token_decimals),
       funded_claimable_stake_token_raw: funded_claimable_stake_token_raw,
       funded_claimable_stake_token:
         format_units(funded_claimable_stake_token_raw, @token_decimals)
     }}
  end

  defp build_wallet_positions(job, addresses) do
    positions =
      addresses
      |> Enum.map(&subject_wallet_position_from_job(job, &1))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, position} -> position end)

    wallet_stake_balance_raw = Enum.reduce(positions, 0, &(&1.wallet_stake_balance_raw + &2))
    claimable_usdc_raw = Enum.reduce(positions, 0, &(&1.claimable_usdc_raw + &2))
    claimable_stake_token_raw = Enum.reduce(positions, 0, &(&1.claimable_stake_token_raw + &2))

    {:ok,
     %{
       wallet_addresses: addresses,
       wallet_count: length(addresses),
       wallet_stake_balance_raw: wallet_stake_balance_raw,
       wallet_stake_balance: format_units(wallet_stake_balance_raw, @token_decimals),
       claimable_usdc_raw: claimable_usdc_raw,
       claimable_usdc: format_units(claimable_usdc_raw, @usdc_decimals),
       claimable_stake_token_raw: claimable_stake_token_raw,
       claimable_stake_token: format_units(claimable_stake_token_raw, @token_decimals)
     }}
  end

  defp load_ingress_accounts(job, subject_id) do
    case Autolaunch.LocalCache.fetch(ingress_accounts_cache_key(job, subject_id), 30, fn ->
           {:ok, read_ingress_accounts(job, subject_id)}
         end) do
      {:ok, accounts} -> accounts
      {:error, _reason} -> read_ingress_accounts(job, subject_id)
    end
  end

  defp read_ingress_accounts(job, subject_id) do
    factory = revenue_ingress_factory_address(job.chain_id)

    if blank?(factory) do
      %{default_address: job.default_ingress_address, accounts: default_ingress_list(job)}
    else
      count =
        call_uint(
          job.chain_id,
          factory,
          Abi.encode_bytes32_call(:ingress_account_count, subject_id)
        )

      usdc_address = splitter_usdc(job)

      accounts =
        if count == 0 do
          []
        else
          Enum.map(0..(count - 1), fn index ->
            address =
              call_address(
                job.chain_id,
                factory,
                Abi.encode_two_arg_call(
                  :ingress_account_at,
                  {:bytes32, subject_id},
                  {:uint256, index}
                )
              )

            balance_raw =
              call_uint(job.chain_id, usdc_address, Abi.encode_address_call(:balance_of, address))

            %{
              address: address,
              usdc_balance_raw: balance_raw,
              usdc_balance: format_units(balance_raw, @usdc_decimals),
              is_default: false
            }
          end)
        end

      default_address =
        call_address(
          job.chain_id,
          factory,
          Abi.encode_bytes32_call(:default_ingress_of_subject, subject_id)
        )

      %{
        default_address: default_address,
        accounts:
          Enum.map(accounts, fn account ->
            Map.put(account, :is_default, account.address == default_address)
          end)
      }
    end
  end

  defp load_share_change_history(job) do
    case Autolaunch.LocalCache.fetch(share_history_cache_key(job), 60, fn ->
           {:ok, read_share_change_history(job)}
         end) do
      {:ok, history} -> history
      {:error, _reason} -> read_share_change_history(job)
    end
  end

  defp read_share_change_history(job) do
    from_block = splitter_history_start_block(job)

    case Rpc.get_logs(job.chain_id, %{
           "address" => job.revenue_share_splitter_address,
           "fromBlock" => encode_block_number(from_block),
           "toBlock" => "latest"
         }) do
      {:ok, logs} ->
        logs
        |> Enum.map(&decode_share_change_log(job.chain_id, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{&1.block_number || 0, &1.log_index || 0})

      _ ->
        []
    end
  end

  defp splitter_history_start_block(job) do
    case normalize_tx_hash(job.tx_hash || "") do
      {:ok, tx_hash} ->
        case Rpc.tx_receipt(job.chain_id, tx_hash) do
          {:ok, %{block_number: block_number}}
          when is_integer(block_number) and block_number >= 0 ->
            block_number

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp decode_share_change_log(chain_id, %{topics: [topic0 | _]} = log)
       when topic0 in [
              @eligible_share_proposed_topic0,
              @eligible_share_cancelled_topic0,
              @eligible_share_activated_topic0
            ] do
    timestamp = block_timestamp(chain_id, log.block_number)

    case topic0 do
      @eligible_share_proposed_topic0 ->
        with {:ok, current_bps} <- decode_indexed_uint16(Enum.at(log.topics, 1)),
             {:ok, pending_bps} <- decode_indexed_uint16(Enum.at(log.topics, 2)),
             {:ok, eta_raw} <- Abi.decode_uint256_word(log.data) do
          %{
            type: "proposed",
            current_share_bps: current_bps,
            current_share_percent: bps_to_percent_string(current_bps),
            pending_share_bps: pending_bps,
            pending_share_percent: bps_to_percent_string(pending_bps),
            activation_eta_raw: eta_raw,
            activation_eta: format_unix_timestamp(eta_raw),
            happened_at: timestamp && format_unix_timestamp(timestamp),
            happened_at_raw: timestamp,
            transaction_hash: log.transaction_hash,
            block_number: log.block_number,
            log_index: log.log_index
          }
        end

      @eligible_share_cancelled_topic0 ->
        with {:ok, cancelled_bps} <- decode_indexed_uint16(Enum.at(log.topics, 1)),
             {:ok, cooldown_end_raw} <- Abi.decode_uint256_word(log.data) do
          %{
            type: "cancelled",
            cancelled_share_bps: cancelled_bps,
            cancelled_share_percent: bps_to_percent_string(cancelled_bps),
            cooldown_end_raw: cooldown_end_raw,
            cooldown_end: format_unix_timestamp(cooldown_end_raw),
            happened_at: timestamp && format_unix_timestamp(timestamp),
            happened_at_raw: timestamp,
            transaction_hash: log.transaction_hash,
            block_number: log.block_number,
            log_index: log.log_index
          }
        end

      @eligible_share_activated_topic0 ->
        with {:ok, previous_bps} <- decode_indexed_uint16(Enum.at(log.topics, 1)),
             {:ok, new_bps} <- decode_indexed_uint16(Enum.at(log.topics, 2)),
             {:ok, [activated_at_raw, cooldown_end_raw]} <- decode_uint_words(log.data, 2) do
          %{
            type: "activated",
            previous_share_bps: previous_bps,
            previous_share_percent: bps_to_percent_string(previous_bps),
            new_share_bps: new_bps,
            new_share_percent: bps_to_percent_string(new_bps),
            activation_raw: activated_at_raw,
            activation: format_unix_timestamp(activated_at_raw),
            cooldown_end_raw: cooldown_end_raw,
            cooldown_end: format_unix_timestamp(cooldown_end_raw),
            happened_at: timestamp && format_unix_timestamp(timestamp),
            happened_at_raw: timestamp,
            transaction_hash: log.transaction_hash,
            block_number: log.block_number,
            log_index: log.log_index
          }
        end
    end
  rescue
    _ -> nil
  end

  defp decode_share_change_log(_chain_id, _log), do: nil

  defp block_timestamp(_chain_id, nil), do: nil

  defp block_timestamp(chain_id, block_number) when is_integer(block_number) do
    key = "autolaunch:block:#{chain_id}:#{block_number}:timestamp"

    case Autolaunch.LocalCache.fetch(key, 86_400, fn ->
           case Rpc.block_by_number(chain_id, block_number) do
             {:ok, %{timestamp: timestamp}} when is_integer(timestamp) -> {:ok, timestamp}
             _ -> {:ok, nil}
           end
         end) do
      {:ok, timestamp} -> timestamp
      {:error, _reason} -> nil
    end
  end

  defp default_ingress_list(job) do
    if blank?(job.default_ingress_address) do
      []
    else
      balance_raw = balance_raw(job, job.default_ingress_address)

      [
        %{
          address: job.default_ingress_address,
          usdc_balance_raw: balance_raw,
          usdc_balance: format_units(balance_raw, @usdc_decimals),
          is_default: true
        }
      ]
    end
  end

  defp splitter_usdc(job) do
    call_address(job.chain_id, job.revenue_share_splitter_address, Abi.encode_no_args(:usdc))
  end

  defp can_manage_subject?(job, subject_id, wallet_address) do
    job.chain_id
    |> Rpc.eth_call(
      job.subject_registry_address,
      Abi.encode_two_arg_call(
        :can_manage_subject,
        {:bytes32, subject_id},
        {:address, wallet_address}
      )
    )
    |> case do
      {:ok, <<"0x", _::binary-size(63), "1">>} -> true
      _ -> false
    end
  end

  defp validate_ingress(subject, ingress_address) do
    normalized = normalize_address(ingress_address)
    ingress = Enum.find(subject.ingress_accounts, &(&1.address == normalized))
    if ingress, do: {:ok, ingress}, else: {:error, :ingress_not_found}
  end

  defp format_accounting_tag(tag) do
    amount_raw = tag.amount_raw

    %{
      source: tag.source,
      ingress_address: tag.ingress_address,
      splitter_address: Map.get(tag, :splitter_address),
      tag_index: tag.tag_index,
      block_number: tag.block_number,
      log_block_number: tag.log_block_number,
      depositor: tag.depositor,
      amount_raw: amount_raw,
      amount: format_units(amount_raw, @usdc_decimals),
      label: tag.label,
      transaction_hash: tag.transaction_hash,
      log_index: tag.log_index
    }
  end

  defp call_uint(chain_id, to, data) do
    {:ok, result} = Rpc.eth_call(chain_id, to, data)
    Abi.decode_uint256(result)
  end

  defp call_address(chain_id, to, data) do
    {:ok, result} = Rpc.eth_call(chain_id, to, data)
    Abi.decode_address(result)
  end

  defp missing_subject, do: {:error, :not_found}
  defp wallet_issue, do: {:error, :unauthorized}
  defp unavailable_subject_data, do: {:error, :subject_lookup_failed}
  defp bad_amount, do: {:error, :amount_required}

  defp required_non_negative_int(attrs, key, missing_error, invalid_error) do
    case Map.get(attrs, key) do
      nil -> {:error, missing_error}
      value -> parse_non_negative_int(value, invalid_error)
    end
  end

  defp optional_non_negative_int(attrs, key, default, error) do
    case Map.get(attrs, key) do
      nil ->
        {:ok, default}

      value ->
        case parse_non_negative_int(value, error) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _reason} = error -> error
        end
    end
  end

  defp optional_limit(attrs, key, default) do
    with {:ok, limit} <- optional_non_negative_int(attrs, key, default, :invalid_limit),
         true <- limit >= 1 and limit <= 100 do
      {:ok, limit}
    else
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_non_negative_int(value, _error) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp parse_non_negative_int(value, error) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, error}
    end
  end

  defp parse_non_negative_int(_value, error), do: {:error, error}

  defp required_wallet(current_actor) do
    case primary_wallet_address(current_actor) do
      nil -> wallet_issue()
      address -> {:ok, address}
    end
  end

  defp primary_wallet_address(%HumanUser{} = human) do
    [human.wallet_address | List.wrap(human.wallet_addresses)]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> normalize_address()
  end

  defp primary_wallet_address(%{"wallet_address" => wallet_address}) do
    wallet_address
    |> normalize_primary_wallet()
  end

  defp primary_wallet_address(%{wallet_address: wallet_address}) do
    wallet_address
    |> normalize_primary_wallet()
  end

  defp primary_wallet_address(_human), do: nil

  defp normalize_primary_wallet(value) do
    case normalize_address(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_address_list(values) when is_list(values) do
    values
    |> Enum.map(fn value ->
      normalized = normalize_address(value)

      if is_binary(normalized) and Regex.match?(~r/^0x[0-9a-f]{40}$/, normalized),
        do: normalized,
        else: nil
    end)
    |> Enum.reduce_while([], fn
      nil, _acc -> {:halt, {:error, :invalid_address}}
      address, acc -> {:cont, [address | acc]}
    end)
    |> case do
      {:error, _} = error -> error
      addresses -> {:ok, addresses |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp normalize_address_list(_values), do: {:error, :invalid_address}

  defp normalize_required_address(value) when is_binary(value) do
    normalized = normalize_address(value)

    if is_binary(normalized) and Regex.match?(~r/^0x[0-9a-f]{40}$/, normalized),
      do: {:ok, normalized},
      else: {:error, :invalid_address}
  end

  defp normalize_required_address(_value), do: {:error, :invalid_address}

  defp prepare_subject_action!(action, subject, wallet_address, request) do
    request = Map.new(request)

    params =
      request
      |> Map.get(:params, %{})
      |> Map.merge(%{subject_id: subject.subject_id})

    {:ok, prepared} =
      ActionParams.prepare_tx_request(
        request,
        "subject",
        action_name(action),
        params,
        expected_signer: wallet_address
      )

    prepared
  end

  defp chain_label(84_532), do: "Base Sepolia"
  defp chain_label(8_453), do: "Base"
  defp chain_label(_chain_id), do: "Base"

  defp parse_token_amount(value) when is_binary(value) do
    with {decimal, ""} <- Decimal.parse(String.trim(value)),
         true <- Decimal.compare(decimal, 0) == :gt || bad_amount() do
      {:ok, decimal_to_units(decimal, @token_decimals)}
    else
      :error -> bad_amount()
      {:error, _} = error -> error
      _ -> bad_amount()
    end
  end

  defp parse_token_amount(_value), do: bad_amount()

  defp decimal_to_units(decimal, decimals) do
    factor = Decimal.new(integer_pow10(decimals))

    decimal
    |> Decimal.mult(factor)
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp format_units(nil, _decimals), do: nil

  defp format_units(value, decimals) when is_integer(value) do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new(integer_pow10(decimals)))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp bps_to_percent_string(value) when is_integer(value) and value >= 0 do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new(100))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp percent_or_nil(0), do: nil
  defp percent_or_nil(value) when is_integer(value), do: bps_to_percent_string(value)
  defp percent_or_nil(_value), do: nil

  defp format_unix_timestamp(nil), do: nil

  defp format_unix_timestamp(value) when is_integer(value) and value > 0 do
    value
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp format_unix_timestamp(_value), do: nil

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(value), do: value

  defp encode_block_number(value) when is_integer(value) and value >= 0 do
    "0x" <> Integer.to_string(value, 16)
  end

  defp decode_indexed_uint16(topic) when is_binary(topic) do
    case Abi.decode_uint256_word(topic) do
      {:ok, value} when value <= 65_535 -> {:ok, value}
      _ -> {:error, :invalid_indexed_uint16}
    end
  end

  defp decode_indexed_uint16(_topic), do: {:error, :invalid_indexed_uint16}

  defp decode_uint_words("0x" <> hex, count) when is_integer(count) and count >= 0 do
    if byte_size(hex) == count * 64 do
      hex
      |> split_words(count, [])
      |> Enum.map(&Abi.decode_uint256_word/1)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
        _error, _acc -> {:halt, {:error, :invalid_word_data}}
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_word_data}
    end
  end

  defp decode_uint_words(_value, _count), do: {:error, :invalid_word_data}

  defp split_words(_hex, 0, acc), do: Enum.reverse(acc)

  defp split_words(hex, count, acc) when count > 0 do
    <<word::binary-size(64), rest::binary>> = hex
    split_words(rest, count - 1, ["0x" <> word | acc])
  end

  defp positive_difference(left, right) when left > right, do: left - right
  defp positive_difference(_left, _right), do: 0

  defp normalize_subject_id("0x" <> hex = subject_id) when byte_size(hex) == 64 do
    {:ok, String.downcase(subject_id)}
  end

  defp normalize_subject_id(_subject_id), do: {:error, :invalid_subject_id}

  defp normalize_address(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_address(_value), do: nil

  defp normalize_hash(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_hash(value), do: value

  defp revenue_ingress_factory_address(chain_id) do
    case launch_chain_id() do
      {:ok, ^chain_id} ->
        InfrastructureConfig.launch_address(:revenue_ingress_factory_address)

      _ ->
        nil
    end
  end

  defp launch_chain_id do
    InfrastructureConfig.launch_chain_id()
  end

  defp tx_hash_param(attrs) do
    case Map.get(attrs, "tx_hash") do
      nil -> {:ok, nil}
      value when is_binary(value) -> normalize_tx_hash(value)
      _ -> {:error, :invalid_transaction_hash}
    end
  end

  defp normalize_tx_hash(tx_hash) do
    trimmed = String.downcase(String.trim(tx_hash))

    if Regex.match?(~r/^0x[0-9a-f]{64}$/, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_transaction_hash}
    end
  end

  defp subject_cache_key(job, subject_id, owner_address) do
    owner = owner_address || "none"

    Enum.join(
      [
        "autolaunch",
        "subject",
        job.chain_id,
        normalize_address(job.revenue_share_splitter_address),
        normalize_address(subject_id),
        "owner",
        normalize_address(owner),
        "v",
        subject_cache_epoch(subject_id)
      ],
      ":"
    )
  end

  defp wallet_positions_cache_key(job, subject_id, addresses) do
    Enum.join(
      [
        "autolaunch",
        "subject",
        job.chain_id,
        normalize_address(job.revenue_share_splitter_address),
        normalize_address(subject_id),
        "wallets",
        RegentCache.digest(addresses),
        "v",
        subject_cache_epoch(subject_id)
      ],
      ":"
    )
  end

  defp obligation_metrics_cache_key(job, subject_id, addresses) do
    Enum.join(
      [
        "autolaunch",
        "subject",
        job.chain_id,
        normalize_address(job.revenue_share_splitter_address),
        normalize_address(subject_id),
        "obligations",
        RegentCache.digest(addresses),
        "v",
        subject_cache_epoch(subject_id)
      ],
      ":"
    )
  end

  defp ingress_accounts_cache_key(job, subject_id) do
    Enum.join(
      [
        "autolaunch",
        "subject",
        job.chain_id,
        normalize_address(job.revenue_share_splitter_address),
        normalize_address(subject_id),
        "ingress",
        "v",
        subject_cache_epoch(subject_id)
      ],
      ":"
    )
  end

  defp share_history_cache_key(job) do
    Enum.join(
      [
        "autolaunch",
        "subject",
        job.chain_id,
        normalize_address(job.revenue_share_splitter_address),
        "share-history",
        "v",
        subject_cache_epoch(job.subject_id)
      ],
      ":"
    )
  end

  defp subject_cache_epoch(subject_id) do
    key = subject_epoch_key(subject_id)

    case Autolaunch.LocalCache.get_string(key) do
      {:ok, value} when is_binary(value) -> value
      _ -> "0"
    end
  end

  defp bump_subject_cache_epoch(subject_id) do
    _ = Autolaunch.LocalCache.increment(subject_epoch_key(subject_id), 86_400)
    :ok
  end

  defp subject_epoch_key(subject_id) do
    "autolaunch:subject:#{normalize_address(subject_id)}:epoch"
  end

  defp blank?(value), do: value in [nil, ""]

  defp balance_raw(job, address) do
    call_uint(job.chain_id, splitter_usdc(job), Abi.encode_address_call(:balance_of, address))
  end

  defp integer_pow10(exponent) when exponent >= 0 do
    Integer.pow(10, exponent)
  end
end
