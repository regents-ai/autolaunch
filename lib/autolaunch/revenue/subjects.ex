defmodule Autolaunch.Revenue.Subjects do
  @moduledoc false

  import Ecto.Query

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts.{Abi, ActionParams}
  alias Autolaunch.Evm
  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.Repo
  alias Autolaunch.Revenue.Core
  alias Autolaunch.Revenue.RevenueSubject

  @usdc_decimals 6
  @token_decimals 18
  @existing_token_created_topic0 "0x03b5cbf19327bec5313dcb772dc0ecb35f8f7fcfafe897639b0a54eebcdd9b1c"
  @deferred_autolaunch_created_topic0 "0x36f06b6cb88844b276b8212d9b26f9948c1fff57ac44de768a170596122491f1"
  @zero_address "0x0000000000000000000000000000000000000000"
  @max_token_name_bytes 64
  @max_token_symbol_bytes 16
  @max_label_bytes 96
  @max_token_factory_data_bytes 1024

  defdelegate get_subject(subject_id, current_human \\ nil), to: Core
  defdelegate subject_scope(subject_id, current_human \\ nil), to: Core
  defdelegate subject_state(subject_id, current_human \\ nil), to: Core

  defdelegate subject_portfolio_state(subject_id, wallet_addresses, current_human \\ nil),
    to: Core

  def prepare_existing_token_subject(attrs, current_actor) do
    with {:ok, signer} <- signer_for(current_actor),
         {:ok, chain_id} <- InfrastructureConfig.launch_chain_id(),
         {:ok, factory} <- configured_factory(:existing_token_revenue_factory_address),
         {:ok, stake_token} <- address_param(attrs, "stake_token"),
         {:ok, treasury} <- address_param(attrs, "treasury"),
         {:ok, staker_pool_bps} <- uint16_bps_param(attrs, "staker_pool_bps"),
         {:ok, label} <- label_param(attrs, "label"),
         {:ok, salt} <- bytes32_param(attrs, "salt", random: true) do
      params = %{
        resource_id: stake_token,
        expected_signer: signer,
        stake_token: stake_token,
        treasury: treasury,
        staker_pool_bps: staker_pool_bps,
        label: label,
        salt: salt
      }

      data =
        Abi.encode_call(:create_existing_token_revenue_subject, [
          {:tuple,
           [
             {:address, stake_token},
             {:address, treasury},
             {:uint16, staker_pool_bps},
             {:string, label},
             {:bytes32, salt}
           ]}
        ])

      with {:ok, prepared} <-
             ActionParams.prepare_tx(
               chain_id,
               factory,
               data,
               "subject",
               "create_existing_token",
               params,
               expected_signer: signer
             ) do
        {:ok, %{subject: nil, prepared: prepared}}
      end
    end
  end

  def prepare_deferred_autolaunch(attrs, current_actor) do
    with {:ok, signer} <- signer_for(current_actor),
         {:ok, chain_id} <- InfrastructureConfig.launch_chain_id(),
         {:ok, factory} <- configured_factory(:deferred_autolaunch_factory_address),
         {:ok, token_name} <- label_param(attrs, "token_name", @max_token_name_bytes),
         {:ok, token_symbol} <- label_param(attrs, "token_symbol", @max_token_symbol_bytes),
         {:ok, total_supply} <- uint_param(attrs, "total_supply"),
         {:ok, treasury} <- address_param(attrs, "treasury"),
         {:ok, token_factory_data} <-
           bytes_param(attrs, "token_factory_data", @max_token_factory_data_bytes),
         {:ok, token_factory_salt} <- bytes32_param(attrs, "token_factory_salt", random: true),
         {:ok, subject_label} <- label_param(attrs, "subject_label"),
         {:ok, identity_chain_id, identity_registry, identity_agent_id} <- identity_tuple(attrs) do
      params = %{
        resource_id: token_symbol,
        expected_signer: signer,
        token_name: token_name,
        token_symbol: token_symbol,
        total_supply: Integer.to_string(total_supply),
        treasury: treasury,
        token_factory_data: token_factory_data,
        token_factory_salt: token_factory_salt,
        subject_label: subject_label,
        identity_chain_id: identity_chain_id,
        identity_registry: identity_registry,
        identity_agent_id: identity_agent_id
      }

      data =
        Abi.encode_call(:create_deferred_autolaunch, [
          {:tuple,
           [
             {:string, token_name},
             {:string, token_symbol},
             {:uint256, total_supply},
             {:address, treasury},
             {:bytes, token_factory_data},
             {:bytes32, token_factory_salt},
             {:string, subject_label},
             {:uint256, identity_chain_id},
             {:address, identity_registry},
             {:uint256, identity_agent_id}
           ]}
        ])

      with {:ok, prepared} <-
             ActionParams.prepare_tx(
               chain_id,
               factory,
               data,
               "subject",
               "create_deferred_autolaunch",
               params,
               expected_signer: signer
             ) do
        {:ok, %{subject: nil, prepared: prepared}}
      end
    end
  end

  def confirm_existing_token_subject(attrs, current_actor) do
    with {:ok, signer} <- signer_for(current_actor),
         {:ok, chain_id} <- InfrastructureConfig.launch_chain_id(),
         {:ok, factory} <- configured_factory(:existing_token_revenue_factory_address),
         {:ok, tx_hash} <- transaction_hash(attrs),
         {:ok, tx} <- confirmed_transaction(chain_id, tx_hash),
         :ok <- validate_transaction_sender(tx, signer),
         :ok <- validate_transaction_target(tx, factory),
         {:ok, receipt} <- confirmed_receipt(chain_id, tx_hash),
         :ok <- validate_transaction_hash(receipt, tx_hash),
         :ok <- validate_transaction_sender(receipt, signer),
         :ok <- validate_transaction_target(receipt, factory),
         {:ok, decoded} <- decode_existing_token_created(receipt, factory),
         :ok <- validate_event_creator(decoded.creator, signer),
         {:ok, subject} <-
           upsert_revenue_subject(%{
             subject_id: decoded.subject_id,
             chain_id: chain_id,
             subject_kind: "existing_token_revenue",
             splitter_kind: "live_stake_fee_pool",
             token_address: decoded.stake_token,
             splitter_address: decoded.splitter,
             ingress_address: decoded.ingress,
             treasury_address: decoded.treasury,
             factory_address: factory,
             creator_address: decoded.creator,
             permissionless: true,
             staker_pool_bps: decoded.staker_pool_bps,
             protocol_fee_usdc_total_raw: "0",
             regent_emission_total_raw: "0",
             regent_buyback_total_raw: "0",
             team_shared_status: "unverified",
             created_tx_hash: tx_hash,
             created_block_number: decoded.block_number,
             created_log_index: decoded.log_index
           }) do
      {:ok, %{subject: serialize_subject(subject)}}
    end
  end

  def confirm_deferred_autolaunch(attrs, current_actor) do
    with {:ok, signer} <- signer_for(current_actor),
         {:ok, chain_id} <- InfrastructureConfig.launch_chain_id(),
         {:ok, factory} <- configured_factory(:deferred_autolaunch_factory_address),
         {:ok, tx_hash} <- transaction_hash(attrs),
         {:ok, tx} <- confirmed_transaction(chain_id, tx_hash),
         :ok <- validate_transaction_sender(tx, signer),
         :ok <- validate_transaction_target(tx, factory),
         {:ok, receipt} <- confirmed_receipt(chain_id, tx_hash),
         :ok <- validate_transaction_hash(receipt, tx_hash),
         :ok <- validate_transaction_sender(receipt, signer),
         :ok <- validate_transaction_target(receipt, factory),
         {:ok, decoded} <- decode_deferred_autolaunch_created(receipt, factory),
         :ok <- validate_event_creator(decoded.creator, signer),
         {:ok, subject} <-
           upsert_revenue_subject(%{
             subject_id: decoded.subject_id,
             chain_id: chain_id,
             subject_kind: "deferred_autolaunch",
             splitter_kind: "denominator_v2",
             token_address: decoded.token,
             splitter_address: decoded.splitter,
             ingress_address: decoded.ingress,
             treasury_address: decoded.treasury,
             factory_address: factory,
             creator_address: decoded.creator,
             permissionless: false,
             protocol_fee_usdc_total_raw: "0",
             regent_emission_total_raw: "0",
             regent_buyback_total_raw: "0",
             team_shared_status: "unverified",
             vesting_wallet_address: decoded.vesting_wallet,
             created_tx_hash: tx_hash,
             created_block_number: decoded.block_number,
             created_log_index: decoded.log_index
           }) do
      {:ok, %{subject: serialize_subject(subject)}}
    end
  end

  def subjects_by_token(token) do
    with {:ok, token_address} <- token_param(token),
         {:ok, chain_id} <- InfrastructureConfig.launch_chain_id() do
      subjects =
        RevenueSubject
        |> where(
          [subject],
          subject.chain_id == ^chain_id and subject.token_address == ^token_address
        )
        |> order_by([subject], desc: subject.inserted_at)
        |> Repo.all()
        |> Enum.map(&serialize_subject/1)

      {:ok, %{token_address: token_address, subjects: subjects}}
    end
  end

  def subject_staking(subject_id) do
    with {:ok, subject_id} <- bytes32_param(%{"id" => subject_id}, "id"),
         %RevenueSubject{} = subject <-
           Repo.get(RevenueSubject, subject_id) || {:error, :revenue_subject_not_found} do
      total_staked_raw = safe_uint_call(subject.chain_id, subject.splitter_address, :total_staked)

      {:ok,
       %{
         subject_id: subject.subject_id,
         staking: %{
           subject_kind: subject.subject_kind,
           splitter_kind: subject.splitter_kind,
           splitter_address: subject.splitter_address,
           token_address: subject.token_address,
           staker_pool_bps: subject.staker_pool_bps,
           total_staked_raw: total_staked_raw,
           total_staked: format_units(total_staked_raw, @token_decimals)
         }
       }}
    end
  end

  def subject_protocol_fee_settlements(subject_id) do
    with {:ok, subject_id} <- bytes32_param(%{"id" => subject_id}, "id"),
         %RevenueSubject{} <-
           Repo.get(RevenueSubject, subject_id) || {:error, :revenue_subject_not_found} do
      {:ok, %{subject_id: subject_id, settlements: []}}
    end
  end

  def subject_regent_emissions(subject_id) do
    with {:ok, subject_id} <- bytes32_param(%{"id" => subject_id}, "id"),
         %RevenueSubject{} <-
           Repo.get(RevenueSubject, subject_id) || {:error, :revenue_subject_not_found} do
      {:ok, %{subject_id: subject_id, emissions: []}}
    end
  end

  defp configured_factory(key) do
    case InfrastructureConfig.launch_address(key) do
      "0x" <> _ = address -> {:ok, address}
      _ -> {:error, :factory_unconfigured}
    end
  end

  defp upsert_revenue_subject(attrs) do
    %RevenueSubject{}
    |> RevenueSubject.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :subject_kind,
           :splitter_kind,
           :token_address,
           :splitter_address,
           :ingress_address,
           :treasury_address,
           :factory_address,
           :creator_address,
           :permissionless,
           :staker_pool_bps,
           :protocol_skim_bps_snapshot,
           :current_protocol_skim_bps,
           :protocol_fee_usdc_total_raw,
           :regent_emission_total_raw,
           :regent_buyback_total_raw,
           :oracle_kind,
           :regent_weth_pool_id,
           :team_shared_status,
           :vesting_wallet_address,
           :created_tx_hash,
           :created_block_number,
           :created_log_index,
           :updated_at
         ]},
      conflict_target: :subject_id
    )
  end

  defp confirmed_receipt(chain_id, tx_hash) do
    case Rpc.tx_receipt(chain_id, tx_hash) do
      {:ok, nil} -> {:error, :transaction_pending}
      {:ok, %{status: 0}} -> {:error, :transaction_failed}
      {:ok, %{status: 1} = receipt} -> {:ok, receipt}
      {:ok, _receipt} -> {:error, :transaction_receipt_unavailable}
      {:error, _reason} -> {:error, :transaction_receipt_unavailable}
    end
  end

  defp confirmed_transaction(chain_id, tx_hash) do
    case Rpc.tx_by_hash(chain_id, tx_hash) do
      {:ok, %{block_number: block_number} = tx} when not is_nil(block_number) -> {:ok, tx}
      {:ok, nil} -> {:error, :transaction_receipt_unavailable}
      {:ok, _tx} -> {:error, :transaction_pending}
      {:error, _reason} -> {:error, :transaction_receipt_unavailable}
    end
  end

  defp validate_transaction_hash(record, tx_hash) do
    case normalized_hash_field(record, :transaction_hash) do
      nil -> :ok
      ^tx_hash -> :ok
      _other -> {:error, :transaction_receipt_unavailable}
    end
  end

  defp validate_transaction_sender(record, signer) do
    if normalized_address_field(record, :from) == Evm.normalize_address(signer),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp validate_transaction_target(record, target) do
    if normalized_address_field(record, :to) == Evm.normalize_address(target),
      do: :ok,
      else: {:error, :transaction_target_mismatch}
  end

  defp validate_event_creator(creator, signer) do
    if Evm.normalize_address(creator) == Evm.normalize_address(signer),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp normalized_hash_field(record, field) do
    case Map.get(record, field) || Map.get(record, Atom.to_string(field)) do
      value when is_binary(value) -> String.downcase(value)
      _ -> nil
    end
  end

  defp normalized_address_field(record, field) do
    case Map.get(record, field) || Map.get(record, Atom.to_string(field)) do
      value when is_binary(value) -> Evm.normalize_address(value)
      _ -> nil
    end
  end

  defp decode_existing_token_created(receipt, factory) do
    receipt
    |> receipt_logs()
    |> Enum.find_value(fn log ->
      if log_address(log) == factory and topic_at(log, 0) == @existing_token_created_topic0 do
        decode_existing_token_log(log)
      end
    end)
    |> case do
      nil -> {:error, :creation_event_not_found}
      result -> result
    end
  end

  defp decode_existing_token_log(log) do
    with {:ok, subject_id} <- decode_topic_bytes32(topic_at(log, 1)),
         {:ok, stake_token} <- decode_topic_address(topic_at(log, 2)),
         {:ok, splitter} <- decode_topic_address(topic_at(log, 3)),
         {:ok,
          [ingress_word, creator_word, treasury_word, staker_pool_bps_word, label_offset_word]} <-
           decode_words_payload(log_data(log), 5),
         {:ok, ingress} <- decode_word_address(ingress_word),
         {:ok, creator} <- decode_word_address(creator_word),
         {:ok, treasury} <- decode_word_address(treasury_word),
         {:ok, staker_pool_bps} <- decode_word_uint(staker_pool_bps_word),
         {:ok, _label} <- decode_string_payload(log_data(log), decode_uint!(label_offset_word)) do
      {:ok,
       %{
         subject_id: subject_id,
         stake_token: stake_token,
         splitter: splitter,
         ingress: ingress,
         creator: creator,
         treasury: treasury,
         staker_pool_bps: staker_pool_bps,
         block_number: log_block_number(log),
         log_index: log_index(log)
       }}
    else
      _ -> {:error, :invalid_creation_event}
    end
  end

  defp decode_deferred_autolaunch_created(receipt, factory) do
    receipt
    |> receipt_logs()
    |> Enum.find_value(fn log ->
      if log_address(log) == factory and topic_at(log, 0) == @deferred_autolaunch_created_topic0 do
        decode_deferred_autolaunch_log(log)
      end
    end)
    |> case do
      nil -> {:error, :creation_event_not_found}
      result -> result
    end
  end

  defp decode_deferred_autolaunch_log(log) do
    with {:ok, creator} <- decode_topic_address(topic_at(log, 1)),
         {:ok, subject_id} <- decode_topic_bytes32(topic_at(log, 2)),
         {:ok, token} <- decode_topic_address(topic_at(log, 3)),
         {:ok, [vesting_word, splitter_word, ingress_word, treasury_word]} <-
           decode_words_payload(log_data(log), 4),
         {:ok, vesting_wallet} <- decode_word_address(vesting_word),
         {:ok, splitter} <- decode_word_address(splitter_word),
         {:ok, ingress} <- decode_word_address(ingress_word),
         {:ok, treasury} <- decode_word_address(treasury_word) do
      {:ok,
       %{
         creator: creator,
         subject_id: subject_id,
         token: token,
         vesting_wallet: vesting_wallet,
         splitter: splitter,
         ingress: ingress,
         treasury: treasury,
         block_number: log_block_number(log),
         log_index: log_index(log)
       }}
    else
      _ -> {:error, :invalid_creation_event}
    end
  end

  defp serialize_subject(%RevenueSubject{} = subject) do
    protocol_fee_raw = parse_optional_uint(subject.protocol_fee_usdc_total_raw) || 0
    emission_raw = parse_optional_uint(subject.regent_emission_total_raw) || 0
    buyback_raw = parse_optional_uint(subject.regent_buyback_total_raw) || 0

    %{
      subject_id: subject.subject_id,
      subject_kind: subject.subject_kind,
      splitter_kind: subject.splitter_kind,
      token_address: subject.token_address,
      splitter_address: subject.splitter_address,
      ingress_address: subject.ingress_address,
      treasury_address: subject.treasury_address,
      factory_address: subject.factory_address,
      creator_address: subject.creator_address,
      permissionless: subject.permissionless,
      staker_pool_bps: subject.staker_pool_bps,
      protocol_skim_bps_snapshot: subject.protocol_skim_bps_snapshot,
      current_protocol_skim_bps: subject.current_protocol_skim_bps,
      protocol_fee_usdc_total: format_units(protocol_fee_raw, @usdc_decimals),
      protocol_fee_usdc_total_raw: protocol_fee_raw,
      regent_emission_total: format_units(emission_raw, @token_decimals),
      regent_emission_total_raw: emission_raw,
      regent_buyback_total: format_units(buyback_raw, @token_decimals),
      regent_buyback_total_raw: buyback_raw,
      oracle_kind: subject.oracle_kind,
      regent_weth_pool_id: subject.regent_weth_pool_id,
      team_shared_status: subject.team_shared_status,
      vesting_wallet_address: subject.vesting_wallet_address
    }
  end

  defp signer_for(nil), do: {:error, :unauthorized}

  defp signer_for(%HumanUser{} = human) do
    signer_from_wallets([human.wallet_address | List.wrap(human.wallet_addresses)])
  end

  defp signer_for(%{"wallet_address" => wallet_address} = actor) do
    signer_from_wallets([wallet_address | List.wrap(Map.get(actor, "wallet_addresses"))])
  end

  defp signer_for(%{"wallet_addresses" => wallet_addresses}) do
    signer_from_wallets(List.wrap(wallet_addresses))
  end

  defp signer_for(%{wallet_address: wallet_address} = actor) do
    signer_from_wallets([wallet_address | List.wrap(Map.get(actor, :wallet_addresses))])
  end

  defp signer_for(%{wallet_addresses: wallet_addresses}) do
    signer_from_wallets(List.wrap(wallet_addresses))
  end

  defp signer_for(_current_actor), do: {:error, :unauthorized}

  defp signer_from_wallets(wallets) do
    wallets
    |> Enum.find_value(&Evm.normalize_address/1)
    |> Evm.normalize_required_address()
  end

  defp address_param(attrs, key), do: ActionParams.address_param(attrs, key)

  defp token_param(value) do
    case Evm.normalize_required_address(value) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> {:error, :invalid_subject_token}
    end
  end

  defp label_param(attrs, key, max_bytes \\ @max_label_bytes) do
    case ActionParams.string_param(attrs, key) do
      {:ok, value} ->
        if byte_size(value) <= max_bytes do
          {:ok, value}
        else
          {:error, :invalid_label}
        end

      {:error, _reason} ->
        {:error, :invalid_label}
    end
  end

  defp uint_param(attrs, key), do: ActionParams.uint_param(attrs, key)

  defp uint16_bps_param(attrs, key) do
    with {:ok, value} <- uint_param(attrs, key),
         true <- value <= 10_000 || {:error, :invalid_uint} do
      {:ok, value}
    end
  end

  defp bytes_param(attrs, key, max_bytes) do
    value = Map.get(attrs, key)

    cond do
      is_nil(value) or value == "" ->
        {:ok, "0x"}

      hex_data?(value) and within_hex_byte_limit?(value, max_bytes) ->
        {:ok, String.downcase(value)}

      true ->
        {:error, :invalid_hex}
    end
  end

  defp bytes32_param(attrs, key, opts \\ []) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        normalize_bytes32(value)

      nil ->
        if Keyword.get(opts, :random, false) do
          {:ok, "0x" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))}
        else
          {:error, :invalid_bytes32}
        end

      _ ->
        {:error, :invalid_bytes32}
    end
  end

  defp normalize_bytes32("0x" <> hex) when byte_size(hex) == 64 do
    if Regex.match?(~r/^[0-9a-fA-F]{64}$/, hex) do
      {:ok, "0x" <> String.downcase(hex)}
    else
      {:error, :invalid_bytes32}
    end
  end

  defp normalize_bytes32(_value), do: {:error, :invalid_bytes32}

  defp transaction_hash(attrs) do
    case normalize_bytes32(Map.get(attrs, "tx_hash")) do
      {:ok, hash} -> {:ok, hash}
      {:error, _reason} -> {:error, :invalid_transaction_hash}
    end
  end

  defp identity_tuple(attrs) do
    values = [
      Map.get(attrs, "identity_chain_id"),
      Map.get(attrs, "identity_registry"),
      Map.get(attrs, "identity_agent_id")
    ]

    if Enum.all?(values, &blank?/1) do
      {:ok, 0, @zero_address, 0}
    else
      with {:ok, chain_id} <- positive_uint_param(attrs, "identity_chain_id"),
           {:ok, registry} <- address_param(attrs, "identity_registry"),
           {:ok, agent_id} <- positive_uint_param(attrs, "identity_agent_id") do
        {:ok, chain_id, registry, agent_id}
      else
        _ -> {:error, :invalid_identity}
      end
    end
  end

  defp positive_uint_param(attrs, key) do
    with {:ok, value} <- uint_param(attrs, key),
         true <- value > 0 || {:error, :invalid_uint} do
      {:ok, value}
    end
  end

  defp safe_uint_call(chain_id, address, selector) when is_binary(address) do
    case Rpc.eth_call(chain_id, address, Autolaunch.Revenue.Abi.encode_no_args(selector)) do
      {:ok, data} ->
        Autolaunch.Revenue.Abi.decode_uint256(data)

      _ ->
        nil
    end
  end

  defp safe_uint_call(_chain_id, _address, _selector), do: nil

  defp receipt_logs(%{logs: logs}) when is_list(logs), do: logs
  defp receipt_logs(%{"logs" => logs}) when is_list(logs), do: logs
  defp receipt_logs(_receipt), do: []

  defp log_address(log), do: normalize_log_address(value_at(log, :address))
  defp log_data(log), do: value_at(log, :data) || "0x"
  defp log_block_number(log), do: value_at(log, :block_number)
  defp log_index(log), do: value_at(log, :log_index)

  defp topic_at(log, index) do
    case value_at(log, :topics) do
      topics when is_list(topics) -> Enum.at(topics, index)
      _ -> nil
    end
  end

  defp value_at(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_log_address(value) when is_binary(value), do: Evm.normalize_address(value)
  defp normalize_log_address(_value), do: nil

  defp decode_topic_bytes32(value), do: normalize_bytes32(value)

  defp decode_topic_address("0x" <> hex) when byte_size(hex) == 64 do
    {:ok, "0x" <> (String.downcase(hex) |> String.slice(-40, 40))}
  end

  defp decode_topic_address(_value), do: {:error, :invalid_address}

  defp decode_word_address(word), do: decode_topic_address(word)

  defp decode_word_uint("0x" <> hex) when byte_size(hex) == 64 do
    {:ok, String.to_integer(hex, 16)}
  end

  defp decode_word_uint(_word), do: {:error, :invalid_uint}

  defp decode_uint!(word) do
    {:ok, value} = decode_word_uint(word)
    value
  end

  defp decode_words_payload("0x" <> hex, expected_count)
       when is_binary(hex) and byte_size(hex) >= expected_count * 64 do
    words =
      hex
      |> String.downcase()
      |> binary_part(0, expected_count * 64)
      |> split_words(expected_count, [])

    {:ok, words}
  end

  defp decode_words_payload(_data, _expected_count), do: {:error, :invalid_hex}

  defp split_words(_data, 0, acc), do: Enum.reverse(acc)

  defp split_words(data, count, acc) do
    <<word::binary-size(64), rest::binary>> = data
    split_words(rest, count - 1, ["0x" <> word | acc])
  end

  defp decode_string_payload("0x" <> hex, offset) when is_integer(offset) and offset >= 0 do
    start = offset * 2

    with true <- byte_size(hex) >= start + 64,
         length_word <- "0x" <> binary_part(hex, start, 64),
         {:ok, byte_length} <- decode_word_uint(length_word),
         data_start <- start + 64,
         true <- byte_size(hex) >= data_start + byte_length * 2,
         string_hex <- binary_part(hex, data_start, byte_length * 2),
         {:ok, decoded} <- Base.decode16(string_hex, case: :mixed) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_string}
    end
  end

  defp decode_string_payload(_data, _offset), do: {:error, :invalid_string}

  defp parse_optional_uint(value) when is_integer(value) and value >= 0, do: value

  defp parse_optional_uint(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_optional_uint(_value), do: nil

  defp format_units(nil, _decimals), do: nil

  defp format_units(value, decimals) when is_integer(value) do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new(integer_pow10(decimals)))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp integer_pow10(decimals), do: Integer.pow(10, decimals)

  defp hex_data?("0x" <> hex),
    do: rem(byte_size(hex), 2) == 0 and Regex.match?(~r/^[0-9a-fA-F]*$/, hex)

  defp hex_data?(_value), do: false

  defp within_hex_byte_limit?(_value, nil), do: true

  defp within_hex_byte_limit?("0x" <> hex, max_bytes),
    do: div(byte_size(hex), 2) <= max_bytes

  defp blank?(value), do: value in [nil, ""]
end
