defmodule Autolaunch.Chain.Envelope do
  @moduledoc false

  alias Autolaunch.Chain.Address

  @ttl_seconds 600
  @confirmable_after_expiry_resources ~w(
    autolaunch_auction
    autolaunch_bid
    autolaunch_subject_wallet
    autolaunch_launch
    autolaunch_stocks_launch
    autolaunch_stocks_fee_admin
    autolaunch_lab_position
  )
  @lab_resources ~w(
    autolaunch_launch
    autolaunch_stocks_launch
    autolaunch_stocks_fee_admin
    autolaunch_auction
    autolaunch_bid
    autolaunch_lab_position
  )

  def new(action, signer, data, opts \\ []) do
    require_nonempty!(action, :action)
    require_calldata!(data)
    data = String.downcase(data)
    signer = normalize_address!(signer)
    {to, resource, contract_name} = identity!(opts)
    to = normalize_address!(to)
    value = "0"
    chain_id = Keyword.get(opts, :chain_id, 8453)
    lab_binding = Keyword.get(opts, :lab_binding)
    risk_copy = Keyword.fetch!(opts, :risk_copy)
    require_nonempty!(resource, :resource)
    require_nonempty!(contract_name, :contract_name)
    require_nonempty!(risk_copy, :risk_copy)
    require_network_context!(resource, chain_id, lab_binding)

    prepared_at = now()
    preparation_nonce = preparation_nonce()

    action_id =
      action_id(
        [resource, action, chain_id, to, value, data, signer, DateTime.to_iso8601(prepared_at)],
        preparation_nonce
      )

    envelope = %{
      action_id: action_id,
      idempotency_key: action_id,
      resource: resource,
      action: action,
      chain_id: chain_id,
      to: to,
      value: value,
      data: data,
      expected_signer: signer,
      prepared_at: DateTime.to_iso8601(prepared_at),
      preparation_nonce: preparation_nonce,
      expires_at: DateTime.add(prepared_at, @ttl_seconds, :second) |> DateTime.to_iso8601(),
      risk_copy: risk_copy,
      approval: Keyword.get(opts, :approval),
      arguments: Keyword.get(opts, :arguments, %{}),
      metadata: %{
        contract_name: contract_name,
        calldata_sha256: sha256(data),
        lab: lab_binding
      }
    }

    Map.put(envelope, :confirmation_token, sign(envelope))
  end

  def valid?(envelope, opts \\ [])

  def valid?(envelope, opts) when is_map(envelope) do
    valid_envelope?(envelope, opts, @ttl_seconds) and fresh?(envelope)
  rescue
    _ -> false
  end

  def valid?(_envelope, _opts), do: false

  def valid_for_confirmation?(envelope, opts \\ [])

  def valid_for_confirmation?(envelope, opts) when is_map(envelope) do
    if field(envelope, :resource) in @confirmable_after_expiry_resources do
      valid_envelope?(envelope, opts, :infinity)
    else
      valid_envelope?(envelope, opts, @ttl_seconds) and fresh?(envelope)
    end
  rescue
    _ -> false
  end

  def valid_for_confirmation?(_envelope, _opts), do: false

  def current_time, do: now()

  defp valid_envelope?(envelope, opts, max_age) do
    with {:ok, signed} <- verify(field(envelope, :confirmation_token), max_age),
         true <- signed == canonical_payload(envelope),
         true <- valid_network_context?(envelope),
         true <- field(envelope, :value) == "0",
         true <- context_matches?(envelope, opts),
         signer <- field(envelope, :expected_signer),
         true <- signer == normalize_address!(signer),
         data <- field(envelope, :data),
         true <- data == String.downcase(data),
         true <- field(envelope, :action_id) == recompute_action_id(envelope),
         true <- field(envelope, :idempotency_key) == field(envelope, :action_id),
         {:ok, prepared_at, _offset} <- DateTime.from_iso8601(field(envelope, :prepared_at)),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(field(envelope, :expires_at)),
         duration when duration in 1..600 <- DateTime.diff(expires_at, prepared_at, :second) do
      true
    else
      _ -> false
    end
  end

  defp fresh?(envelope) do
    with {:ok, expires_at, _offset} <- DateTime.from_iso8601(field(envelope, :expires_at)),
         :gt <- DateTime.compare(expires_at, now()) do
      true
    else
      _ -> false
    end
  end

  defp context_matches?(envelope, opts) do
    option_matches?(opts, :resource, field(envelope, :resource)) and
      action_matches?(opts, field(envelope, :action)) and
      option_matches?(opts, :chain_id, field(envelope, :chain_id)) and
      address_option_matches?(opts, :to, field(envelope, :to)) and
      address_option_matches?(opts, :signer, field(envelope, :expected_signer)) and
      option_matches?(opts, :contract_name, field(field(envelope, :metadata), :contract_name))
  end

  defp option_matches?(opts, key, actual) do
    case Keyword.fetch(opts, key) do
      {:ok, expected} -> actual == expected
      :error -> true
    end
  end

  defp address_option_matches?(opts, key, actual) do
    case Keyword.fetch(opts, key) do
      {:ok, expected} -> actual == normalize_address!(expected)
      :error -> true
    end
  end

  defp action_matches?(opts, actual) do
    case {Keyword.fetch(opts, :action), Keyword.fetch(opts, :actions)} do
      {{:ok, action}, :error} when is_binary(action) and action != "" -> actual == action
      {:error, {:ok, actions}} when is_list(actions) and actions != [] -> actual in actions
      {:error, :error} -> true
      _ -> false
    end
  end

  defp recompute_action_id(envelope) do
    action_id(
      [
        field(envelope, :resource),
        field(envelope, :action),
        field(envelope, :chain_id),
        field(envelope, :to),
        field(envelope, :value),
        field(envelope, :data),
        field(envelope, :expected_signer),
        field(envelope, :prepared_at)
      ],
      field(envelope, :preparation_nonce)
    )
  end

  defp action_id(fields, nonce) do
    fields
    |> maybe_append_nonce(nonce)
    |> Enum.map_join(":", &to_string/1)
    |> sha256()
  end

  defp maybe_append_nonce(fields, nonce) when is_binary(nonce) and nonce != "",
    do: fields ++ [nonce]

  defp maybe_append_nonce(fields, _nonce), do: fields

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp sign(envelope) do
    Phoenix.Token.sign(
      AutolaunchWeb.Endpoint,
      "wallet-action",
      canonical_payload(envelope)
    )
  end

  defp verify(token, max_age) when is_binary(token) do
    Phoenix.Token.verify(AutolaunchWeb.Endpoint, "wallet-action", token, max_age: max_age)
  end

  defp verify(_token, _max_age), do: {:error, :invalid_token}

  defp canonical_payload(envelope) do
    [
      :action_id,
      :idempotency_key,
      :resource,
      :action,
      :chain_id,
      :to,
      :value,
      :data,
      :expected_signer,
      :prepared_at,
      :preparation_nonce,
      :expires_at,
      :risk_copy,
      :approval,
      :arguments,
      :metadata
    ]
    |> Enum.reduce(%{}, fn key, payload ->
      cond do
        Map.has_key?(envelope, key) -> Map.put(payload, key, Map.fetch!(envelope, key))
        Map.has_key?(envelope, Atom.to_string(key)) -> Map.put(payload, key, field(envelope, key))
        true -> payload
      end
    end)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp normalize_address!(value) do
    case Address.normalize(value) do
      {:ok, address} -> address
      :error -> raise ArgumentError, "invalid address"
    end
  end

  defp identity!(opts) do
    {
      Keyword.fetch!(opts, :to),
      Keyword.fetch!(opts, :resource),
      Keyword.fetch!(opts, :contract_name)
    }
  end

  defp require_nonempty!(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_nonempty!(_value, field), do: raise(ArgumentError, "invalid #{field}")

  defp require_calldata!("0x" <> hex)
       when byte_size(hex) > 0 and rem(byte_size(hex), 2) == 0 do
    if String.match?(hex, ~r/^[0-9a-fA-F]+$/), do: :ok, else: raise(ArgumentError, "invalid data")
  end

  defp require_calldata!(_data), do: raise(ArgumentError, "invalid data")

  defp require_network_context!(_resource, 8453, nil), do: :ok

  defp require_network_context!(resource, 31_337, binding)
       when resource in @lab_resources and is_map(binding),
       do: :ok

  defp require_network_context!(_resource, _chain_id, _binding),
    do: raise(ArgumentError, "invalid network context")

  defp valid_network_context?(envelope) do
    binding = field(field(envelope, :metadata), :lab)

    case field(envelope, :chain_id) do
      8453 -> is_nil(binding)
      31_337 -> field(envelope, :resource) in @lab_resources and is_map(binding)
      _other -> false
    end
  end

  defp preparation_nonce, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp now do
    Application.get_env(:autolaunch, :wallet_action_clock, fn -> DateTime.utc_now() end).()
  end
end
