defmodule Autolaunch.Revenue do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.Revenue.Abi
  alias Autolaunch.Revenue.SubjectActionRegistration

  @sepolia_chain_id 11_155_111
  @usdc_decimals 6
  @token_decimals 18

  def get_subject(subject_id, current_human \\ nil) do
    with {:ok, normalized_subject_id} <- normalize_subject_id(subject_id),
         %Job{} = job <- load_subject_job(normalized_subject_id) do
      owner_address = primary_wallet_address(current_human)
      ingress_accounts = load_ingress_accounts(job, normalized_subject_id)
      can_manage = owner_address && can_manage_subject?(job, normalized_subject_id, owner_address)

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

      protocol_reserve_usdc =
        call_uint(
          job.chain_id,
          job.revenue_share_splitter_address,
          Abi.encode_no_args(:protocol_reserve_usdc)
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

      {:ok,
       %{
         subject_id: normalized_subject_id,
         chain_id: job.chain_id,
         chain_label: "Ethereum Sepolia",
         token_address: job.token_address,
         strategy_address: job.strategy_address,
         subject_registry_address: job.subject_registry_address,
         splitter_address: job.revenue_share_splitter_address,
         default_ingress_address:
           Map.get(ingress_accounts, :default_address) || job.default_ingress_address,
         ingress_accounts: ingress_accounts.accounts,
         total_staked_raw: total_staked,
         total_staked: format_units(total_staked, @token_decimals),
         treasury_residual_usdc_raw: treasury_residual_usdc,
         treasury_residual_usdc: format_units(treasury_residual_usdc, @usdc_decimals),
         protocol_reserve_usdc_raw: protocol_reserve_usdc,
         protocol_reserve_usdc: format_units(protocol_reserve_usdc, @usdc_decimals),
         undistributed_dust_usdc_raw: undistributed_dust_usdc,
         undistributed_dust_usdc: format_units(undistributed_dust_usdc, @usdc_decimals),
         wallet_address: owner_address,
         wallet_stake_balance_raw: wallet_stake_balance_raw,
         wallet_stake_balance:
           owner_address && format_units(wallet_stake_balance_raw, @token_decimals),
         wallet_token_balance_raw: wallet_token_balance_raw,
         wallet_token_balance:
           owner_address && format_units(wallet_token_balance_raw, @token_decimals),
         claimable_usdc_raw: claimable_usdc_raw,
         claimable_usdc: owner_address && format_units(claimable_usdc_raw, @usdc_decimals),
         can_manage_ingress: can_manage || false
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :subject_lookup_failed}
  end

  def subject_state(subject_id, current_human \\ nil) do
    with {:ok, subject} <- get_subject(subject_id, current_human) do
      {:ok, %{subject: subject}}
    end
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
          source_ref = source_ref(subject)

          {:ok,
           %{
             subject: subject,
             tx_request:
               serialize_tx_request(%{
                 chain_id: @sepolia_chain_id,
                 to: ingress.address,
                 value_hex: "0x0",
                 data: Abi.encode_sweep_usdc(source_ref)
               })
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

  defp build_write_request(:stake, subject, wallet_address, attrs) do
    with {:ok, amount_wei} <-
           parse_token_amount(Map.get(attrs, "amount") || Map.get(attrs, :amount)) do
      {:ok,
       %{
         subject: subject,
         tx_request:
           serialize_tx_request(%{
             chain_id: @sepolia_chain_id,
             to: subject.splitter_address,
             value_hex: "0x0",
             data: Abi.encode_stake(amount_wei, wallet_address)
           })
       }}
    end
  end

  defp build_write_request(:unstake, subject, wallet_address, attrs) do
    with {:ok, amount_wei} <-
           parse_token_amount(Map.get(attrs, "amount") || Map.get(attrs, :amount)) do
      {:ok,
       %{
         subject: subject,
         tx_request:
           serialize_tx_request(%{
             chain_id: @sepolia_chain_id,
             to: subject.splitter_address,
             value_hex: "0x0",
             data: Abi.encode_unstake(amount_wei, wallet_address)
           })
       }}
    end
  end

  defp build_write_request(:claim_usdc, subject, wallet_address, _attrs) do
    {:ok,
     %{
       subject: subject,
       tx_request:
         serialize_tx_request(%{
           chain_id: @sepolia_chain_id,
           to: subject.splitter_address,
           value_hex: "0x0",
           data: Abi.encode_claim_usdc(wallet_address)
         })
     }}
  end

  defp build_write_request(:sweep_ingress, subject, _wallet_address, _attrs) do
    source_ref = source_ref(subject)

    {:ok,
     %{
       subject: subject,
       tx_request:
         serialize_tx_request(%{
           chain_id: @sepolia_chain_id,
           to: subject.default_ingress_address,
           value_hex: "0x0",
           data: Abi.encode_sweep_usdc(source_ref)
         })
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
         {:ok, registration} <- ensure_registration(registration_attrs) do
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
        with {:ok, refreshed} <- get_subject(subject.subject_id, current_human) do
          {:ok, %{subject: refreshed}}
        end

      true ->
        receipt_state = fetch_receipt_state(subject.chain_id, tx_hash)

        with {:ok, tx} <- fetch_transaction(subject.chain_id, tx_hash),
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
               ),
             {:ok, result} <-
               finalize_registration(registration, receipt_state, subject, current_human) do
          {:ok, result}
        end
    end
  end

  defp registration_attrs(:stake, subject, wallet_address, attrs, tx_hash, _expected_to) do
    with {:ok, amount_wei} <-
           parse_token_amount(Map.get(attrs, "amount") || Map.get(attrs, :amount)) do
      {:ok,
       %{
         subject_id: subject.subject_id,
         action: "stake",
         owner_address: wallet_address,
         chain_id: subject.chain_id,
         tx_hash: tx_hash,
         amount: Integer.to_string(amount_wei),
         amount_wei: amount_wei,
         status: "pending"
       }}
    end
  end

  defp registration_attrs(:unstake, subject, wallet_address, attrs, tx_hash, _expected_to) do
    with {:ok, amount_wei} <-
           parse_token_amount(Map.get(attrs, "amount") || Map.get(attrs, :amount)) do
      {:ok,
       %{
         subject_id: subject.subject_id,
         action: "unstake",
         owner_address: wallet_address,
         chain_id: subject.chain_id,
         tx_hash: tx_hash,
         amount: Integer.to_string(amount_wei),
         amount_wei: amount_wei,
         status: "pending"
       }}
    end
  end

  defp registration_attrs(:claim_usdc, subject, wallet_address, _attrs, tx_hash, _expected_to) do
    {:ok,
     %{
       subject_id: subject.subject_id,
       action: "claim_usdc",
       owner_address: wallet_address,
       chain_id: subject.chain_id,
       tx_hash: tx_hash,
       status: "pending"
     }}
  end

  defp registration_attrs(:sweep_ingress, subject, wallet_address, _attrs, tx_hash, expected_to) do
    {:ok,
     %{
       subject_id: subject.subject_id,
       action: "sweep_ingress",
       owner_address: wallet_address,
       chain_id: subject.chain_id,
       tx_hash: tx_hash,
       ingress_address: expected_to,
       status: "pending"
     }}
  end

  defp ensure_registration(registration_attrs) do
    case Repo.get_by(SubjectActionRegistration, tx_hash: registration_attrs.tx_hash) do
      nil ->
        %SubjectActionRegistration{}
        |> SubjectActionRegistration.create_changeset(registration_attrs)
        |> Repo.insert()

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
    maybe_update_registration(registration, %{
      status: "pending",
      error_code: nil,
      error_message: nil
    })

    {:error, :transaction_pending}
  end

  defp finalize_registration(
         registration,
         {:confirmed, block_number},
         subject,
         current_human
       ) do
    maybe_update_registration(registration, %{
      status: "confirmed",
      block_number: block_number,
      error_code: nil,
      error_message: nil
    })

    with {:ok, refreshed} <- get_subject(subject.subject_id, current_human) do
      {:ok, %{subject: refreshed}}
    end
  end

  defp finalize_registration(registration, {:failed, error_code}, _subject, _current_human) do
    maybe_update_registration(registration, %{
      status: "rejected",
      error_code: Atom.to_string(error_code),
      error_message: default_error_message(error_code)
    })

    {:error, error_code}
  end

  defp maybe_update_registration(%SubjectActionRegistration{} = registration, attrs) do
    registration
    |> SubjectActionRegistration.update_status_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, _registration} -> :ok
      {:error, _} -> :ok
    end
  end

  defp validate_registered_action(
         :stake,
         _subject,
         wallet_address,
         attrs,
         tx,
         expected_to,
         registration_attrs,
         _receipt_state
       ) do
    with {:ok, amount_wei} <-
           parse_token_amount(Map.get(attrs, "amount") || Map.get(attrs, :amount)),
         :ok <- validate_tx_sender(tx, wallet_address),
         :ok <- validate_tx_target(tx, expected_to) do
      case Abi.decode_call_data(tx.input) do
        {:ok, %{action: :stake, amount_wei: decoded_amount, receiver: receiver}} ->
          with :ok <- validate_equal(decoded_amount, amount_wei, :transaction_data_mismatch),
               :ok <-
                 validate_equal(
                   normalize_address(receiver),
                   normalize_address(wallet_address),
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
         :unstake,
         _subject,
         wallet_address,
         attrs,
         tx,
         expected_to,
         registration_attrs,
         _receipt_state
       ) do
    with {:ok, amount_wei} <-
           parse_token_amount(Map.get(attrs, "amount") || Map.get(attrs, :amount)),
         :ok <- validate_tx_sender(tx, wallet_address),
         :ok <- validate_tx_target(tx, expected_to) do
      case Abi.decode_call_data(tx.input) do
        {:ok, %{action: :unstake, amount_wei: decoded_amount, recipient: recipient}} ->
          with :ok <- validate_equal(decoded_amount, amount_wei, :transaction_data_mismatch),
               :ok <-
                 validate_equal(
                   normalize_address(recipient),
                   normalize_address(wallet_address),
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
         subject,
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
        {:ok, %{action: :sweep_ingress, source_ref: source_ref}} ->
          with :ok <-
                 validate_equal(
                   normalize_address(source_ref),
                   normalize_address(subject.subject_id),
                   :transaction_data_mismatch
                 ),
               :ok <-
                 validate_equal(
                   normalize_address(Map.get(registration_attrs, :ingress_address)),
                   normalize_address(expected_to),
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
         _action,
         _subject,
         _wallet_address,
         _attrs,
         nil,
         _expected_to,
         _registration_attrs,
         :pending
       ),
       do: :ok

  defp validate_registered_action(
         _action,
         _subject,
         _wallet_address,
         _attrs,
         nil,
         _expected_to,
         _registration_attrs,
         _receipt_state
       ),
       do: {:error, :transaction_data_mismatch}

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

  defp validate_receipt_state(_tx, chain_id, tx_hash) do
    case Rpc.tx_receipt(chain_id, tx_hash) do
      {:ok, %{status: 1, block_number: block_number}} ->
        {:confirmed, block_number}

      {:ok, %{status: 1}} ->
        {:confirmed, nil}

      {:ok, %{status: 0}} ->
        {:failed, :transaction_failed}

      {:ok, nil} ->
        :pending

      {:error, _} ->
        :pending

      _ ->
        :pending
    end
  end

  defp fetch_transaction(chain_id, tx_hash) do
    case Rpc.tx_by_hash(chain_id, tx_hash) do
      {:ok, tx} -> {:ok, tx}
      {:error, _} -> {:error, :transaction_data_mismatch}
    end
  end

  defp fetch_receipt_state(chain_id, tx_hash) do
    validate_receipt_state(%{}, chain_id, tx_hash)
  end

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

  defp load_subject_job(subject_id) do
    Repo.one(
      from job in Job,
        where: job.subject_id == ^subject_id and job.status == "ready",
        order_by: [desc: job.updated_at],
        limit: 1
    )
  end

  defp load_ingress_accounts(job, subject_id) do
    factory = revenue_ingress_factory_address()

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

  defp default_ingress_list(job) do
    if blank?(job.default_ingress_address) do
      []
    else
      [
        %{
          address: job.default_ingress_address,
          usdc_balance_raw: balance_raw(job, job.default_ingress_address),
          usdc_balance:
            format_units(balance_raw(job, job.default_ingress_address), @usdc_decimals),
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

  defp call_uint(chain_id, to, data) do
    {:ok, result} = Rpc.eth_call(chain_id, to, data)
    Abi.decode_uint256(result)
  end

  defp call_address(chain_id, to, data) do
    {:ok, result} = Rpc.eth_call(chain_id, to, data)
    Abi.decode_address(result)
  end

  defp required_wallet(%HumanUser{} = human) do
    case primary_wallet_address(human) do
      nil -> {:error, :unauthorized}
      address -> {:ok, address}
    end
  end

  defp required_wallet(_human), do: {:error, :unauthorized}

  defp primary_wallet_address(%HumanUser{} = human) do
    [human.wallet_address | List.wrap(human.wallet_addresses)]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> normalize_address()
  end

  defp primary_wallet_address(_human), do: nil

  defp serialize_tx_request(%{chain_id: chain_id, to: to, value_hex: value_hex, data: data}) do
    %{chain_id: chain_id, to: to, value: value_hex, data: data}
  end

  defp parse_token_amount(value) when is_binary(value) do
    with {decimal, ""} <- Decimal.parse(String.trim(value)),
         true <- Decimal.compare(decimal, 0) == :gt || {:error, :amount_required} do
      {:ok, decimal_to_units(decimal, @token_decimals)}
    else
      :error -> {:error, :amount_required}
      {:error, _} = error -> error
      _ -> {:error, :amount_required}
    end
  end

  defp parse_token_amount(_value), do: {:error, :amount_required}

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

  defp normalize_subject_id("0x" <> hex = subject_id) when byte_size(hex) == 64 do
    {:ok, String.downcase(subject_id)}
  end

  defp normalize_subject_id(_subject_id), do: {:error, :invalid_subject_id}

  defp normalize_address(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_address(_value), do: nil

  defp revenue_ingress_factory_address do
    Application.get_env(:autolaunch, :launch, [])
    |> Keyword.get(:revenue_ingress_factory_address, "")
    |> normalize_address()
  end

  defp tx_hash_param(attrs) do
    case Map.get(attrs, "tx_hash", Map.get(attrs, :tx_hash)) do
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

  defp blank?(value), do: value in [nil, ""]

  defp balance_raw(job, address) do
    call_uint(job.chain_id, splitter_usdc(job), Abi.encode_address_call(:balance_of, address))
  end

  defp source_ref(subject), do: subject.subject_id

  defp integer_pow10(exponent) when exponent >= 0 do
    Integer.pow(10, exponent)
  end
end
