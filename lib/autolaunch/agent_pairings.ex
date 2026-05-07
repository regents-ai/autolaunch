defmodule Autolaunch.AgentPairings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.AgentPairings.Session
  alias Autolaunch.Evm
  alias Autolaunch.Repo

  @ttl_seconds 10 * 60
  @code_regex ~r/^AL-([A-Z2-9]{6})-([A-Z2-9]{8})$/
  @code_alphabet String.graphemes("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
  @signature_type "evm_personal_sign"
  @positive_integer_regex ~r/^[1-9][0-9]*$/

  def create_session(%HumanUser{} = human) do
    {pairing_code, challenge_nonce} = generate_pairing_code()
    now = now()

    attrs = %{
      session_id: "pair_" <> Ecto.UUID.generate(),
      human_user_id: human.id,
      privy_user_id: human.privy_user_id,
      status: "pending",
      pairing_code_hash: pairing_code_hash(pairing_code),
      challenge_nonce: challenge_nonce,
      challenge_message: challenge_message(challenge_nonce),
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    %Session{}
    |> Session.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, session} -> {:ok, serialize_session(session, pairing_code)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def create_session(_human), do: {:error, :unauthorized}

  def get_session(%HumanUser{} = human, session_id) when is_binary(session_id) do
    Session
    |> where([session], session.session_id == ^session_id and session.human_user_id == ^human.id)
    |> Repo.one()
    |> case do
      nil -> {:error, :pairing_not_found}
      session -> {:ok, session |> expire_if_needed() |> serialize_session()}
    end
  end

  def get_session(_human, _session_id), do: {:error, :unauthorized}

  def latest_pending_session(%HumanUser{} = human) do
    Session
    |> where([session], session.human_user_id == ^human.id and session.status == "pending")
    |> order_by([session], desc: session.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        nil

      session ->
        session
        |> expire_if_needed()
        |> case do
          %{status: "pending"} = pending -> serialize_session(pending)
          _expired -> nil
        end
    end
  end

  def latest_pending_session(_human), do: nil

  def complete_session(attrs, opts \\ [])

  def complete_session(attrs, opts) when is_map(attrs) do
    with {:ok, input} <- complete_input(attrs) do
      Repo.transaction(fn ->
        with {:ok, session} <- lock_session(input),
             :ok <- ensure_pending(session),
             :ok <- ensure_challenge(session, input.challenge_message),
             :ok <-
               verify_signature(
                 input.challenge_message,
                 input.signature,
                 input.agent_wallet_address
               ),
             {:ok, completed} <- persist_completed_session(session, input, opts) do
          completed
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, session} -> {:ok, serialize_session(session)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def complete_session(_attrs, _opts), do: {:error, :invalid_pairing_request}

  def list_connected_agent_cards(%HumanUser{} = human) do
    Session
    |> where([session], session.human_user_id == ^human.id and session.status == "completed")
    |> order_by([session], desc: session.completed_at)
    |> Repo.all()
    |> Enum.map(&agent_card/1)
  end

  def list_connected_agent_cards(_human), do: []

  def connected_agent_wallet_addresses(%HumanUser{} = human) do
    Session
    |> where([session], session.human_user_id == ^human.id and session.status == "completed")
    |> select([session], session.agent_wallet_address)
    |> Repo.all()
    |> Enum.map(&Evm.normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def connected_agent_wallet_addresses(_human), do: []

  def get_human_by_agent_claims(%{
        "wallet_address" => wallet_address,
        "chain_id" => chain_id,
        "registry_address" => registry_address,
        "token_id" => token_id
      }) do
    with agent_wallet when is_binary(agent_wallet) <- Evm.normalize_address(wallet_address),
         {:ok, parsed_chain_id} <- parse_chain_id(chain_id),
         registry when is_binary(registry) <- Evm.normalize_address(registry_address),
         {:ok, parsed_token_id} <- parse_token_id(token_id) do
      Session
      |> join(:inner, [session], human in HumanUser, on: human.id == session.human_user_id)
      |> where(
        [session, _human],
        session.status == "completed" and
          session.agent_wallet_address == ^agent_wallet and
          session.agent_chain_id == ^parsed_chain_id and
          session.agent_registry_address == ^registry and
          session.agent_token_id == ^parsed_token_id
      )
      |> select([_session, human], human)
      |> limit(1)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  def get_human_by_agent_claims(_claims), do: nil

  def challenge_message(challenge_nonce) when is_binary(challenge_nonce) do
    "Autolaunch agent pairing\n\nPairing: AL-#{challenge_nonce}\nNonce: #{challenge_nonce}"
  end

  def pairing_ttl_seconds, do: @ttl_seconds

  defp complete_input(attrs) do
    with {:ok, pairing_code, challenge_nonce} <-
           required_pairing_code(value(attrs, "pairing_code")),
         {:ok, challenge_message} <- required_text(value(attrs, "challenge_message"), 1_000),
         true <- challenge_message == challenge_message(challenge_nonce),
         {:ok, agent_wallet_address} <- required_address(value(attrs, "agent_wallet_address")),
         {:ok, agent_chain_id} <- parse_chain_id(value(attrs, "agent_chain_id")),
         {:ok, agent_registry_address} <- required_address(value(attrs, "agent_registry_address")),
         {:ok, agent_token_id} <- parse_token_id(value(attrs, "agent_token_id")),
         {:ok, signature_type} <- required_signature_type(value(attrs, "signature_type")),
         {:ok, signature} <- required_text(value(attrs, "signature"), 4_000),
         {:ok, signed_at} <- parse_datetime(value(attrs, "signed_at")) do
      {:ok,
       %{
         pairing_code: pairing_code,
         pairing_code_hash: pairing_code_hash(pairing_code),
         challenge_nonce: challenge_nonce,
         challenge_message: challenge_message,
         agent_wallet_address: agent_wallet_address,
         agent_chain_id: agent_chain_id,
         agent_registry_address: agent_registry_address,
         agent_token_id: agent_token_id,
         agent_id: "#{agent_chain_id}:#{agent_token_id}",
         agent_label: optional_text(value(attrs, "agent_label"), 80),
         signature_type: signature_type,
         signature: signature,
         signed_at: signed_at
       }}
    else
      false -> {:error, :challenge_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_pairing_request}
    end
  end

  defp lock_session(input) do
    Session
    |> where([session], session.challenge_nonce == ^input.challenge_nonce)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil ->
        {:error, :pairing_not_found}

      %{pairing_code_hash: hash} = session when hash == input.pairing_code_hash ->
        {:ok, session}

      _session ->
        {:error, :pairing_not_found}
    end
  end

  defp ensure_pending(%{status: "pending"} = session) do
    if DateTime.compare(session.expires_at, now()) == :gt do
      :ok
    else
      expire_session(session)
      {:error, :pairing_expired}
    end
  end

  defp ensure_pending(%{status: "completed"}), do: {:error, :pairing_completed}
  defp ensure_pending(%{status: "expired"}), do: {:error, :pairing_expired}

  defp ensure_challenge(%{challenge_message: challenge_message}, challenge_message), do: :ok
  defp ensure_challenge(_session, _challenge_message), do: {:error, :challenge_mismatch}

  defp verify_signature(message, signature, wallet_address) do
    signature_module()
    |> apply(:verify_personal_signature, [message, signature, wallet_address])
    |> case do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_signature}
    end
  end

  defp persist_completed_session(session, input, opts) do
    attrs = %{
      status: "completed",
      completed_at: now(),
      agent_wallet_address: input.agent_wallet_address,
      agent_chain_id: input.agent_chain_id,
      agent_registry_address: input.agent_registry_address,
      agent_token_id: input.agent_token_id,
      agent_id: input.agent_id,
      agent_label: input.agent_label,
      signature_type: input.signature_type,
      signature: input.signature,
      signed_message: input.challenge_message,
      signed_at: input.signed_at,
      signed_evidence: signed_evidence(input),
      completion_ip: Keyword.get(opts, :completion_ip)
    }

    session
    |> Session.complete_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, completed} -> {:ok, completed}
      {:error, changeset} -> {:error, completion_changeset_error(changeset)}
    end
  end

  defp expire_if_needed(%{status: "pending"} = session) do
    if DateTime.compare(session.expires_at, now()) == :gt do
      session
    else
      expire_session(session)
    end
  end

  defp expire_if_needed(session), do: session

  defp expire_session(%Session{} = session) do
    session
    |> Session.expire_changeset(%{status: "expired"})
    |> Repo.update()
    |> case do
      {:ok, expired} -> expired
      {:error, _changeset} -> %{session | status: "expired"}
    end
  end

  defp signed_evidence(input) do
    %{
      "agent_wallet_address" => input.agent_wallet_address,
      "agent_chain_id" => input.agent_chain_id,
      "agent_registry_address" => input.agent_registry_address,
      "agent_token_id" => input.agent_token_id,
      "agent_id" => input.agent_id,
      "signature_type" => input.signature_type,
      "signature" => input.signature,
      "signed_message" => input.challenge_message,
      "signed_at" => iso8601(input.signed_at)
    }
  end

  defp completion_changeset_error(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :agent_token_id),
      do: :agent_already_connected,
      else: changeset
  end

  defp agent_card(%Session{} = session) do
    %{
      id: session.agent_id,
      agent_id: session.agent_id,
      name: session.agent_label || "Local Agent #{short_address(session.agent_wallet_address)}",
      source: "pairing_code",
      supported_chains: [],
      state: "connected",
      access_mode: "paired",
      owner_address: session.agent_wallet_address,
      operator_addresses: [],
      agent_wallet: session.agent_wallet_address,
      image_url: nil,
      description: "Connected from Regents CLI.",
      ens: nil,
      agent_uri: nil,
      web_endpoint: nil,
      chain_id: session.agent_chain_id,
      registry_address: session.agent_registry_address,
      token_id: session.agent_token_id,
      linked_wallet_addresses: [session.agent_wallet_address],
      blocker_texts: [],
      lifecycle_run_id: session.agent_id,
      pairing_session_id: session.session_id,
      connected_at: iso8601(session.completed_at),
      existing_token: nil
    }
  end

  defp serialize_session(session), do: serialize_session(session, nil)

  defp serialize_session(%Session{} = session, pairing_code) do
    %{
      session_id: session.session_id,
      status: session.status,
      pairing_code: pairing_code,
      challenge_nonce: session.challenge_nonce,
      challenge_message: session.challenge_message,
      expires_at: iso8601(session.expires_at),
      completed_at: iso8601(session.completed_at),
      inserted_at: iso8601(session.inserted_at),
      updated_at: iso8601(session.updated_at),
      agent: serialize_agent(session)
    }
  end

  defp serialize_agent(%Session{status: "completed"} = session) do
    %{
      agent_id: session.agent_id,
      agent_wallet_address: session.agent_wallet_address,
      agent_chain_id: session.agent_chain_id,
      agent_registry_address: session.agent_registry_address,
      agent_token_id: session.agent_token_id,
      agent_label: session.agent_label,
      connected_at: iso8601(session.completed_at)
    }
  end

  defp serialize_agent(_session), do: nil

  defp generate_pairing_code do
    challenge_nonce = random_segment(6)
    secret = random_segment(8)

    {"AL-#{challenge_nonce}-#{secret}", challenge_nonce}
  end

  defp random_segment(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte -> Enum.at(@code_alphabet, rem(byte, length(@code_alphabet))) end)
  end

  defp required_pairing_code(value) when is_binary(value) do
    case Regex.run(@code_regex, value) do
      [^value, challenge_nonce, _secret] -> {:ok, value, challenge_nonce}
      _ -> {:error, :invalid_pairing_code}
    end
  end

  defp required_pairing_code(_value), do: {:error, :invalid_pairing_code}

  defp pairing_code_hash(pairing_code) do
    :crypto.hash(:sha256, pairing_code)
    |> Base.encode16(case: :lower)
  end

  defp parse_chain_id(value) when is_integer(value) and value in [84_532, 8_453], do: {:ok, value}
  defp parse_chain_id(value) when is_integer(value), do: {:error, :invalid_chain_id}

  defp parse_chain_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parse_chain_id(parsed)
      _ -> {:error, :invalid_chain_id}
    end
  end

  defp parse_chain_id(_value), do: {:error, :invalid_chain_id}

  defp parse_token_id(value) when is_integer(value) and value > 0,
    do: {:ok, Integer.to_string(value)}

  defp parse_token_id(value) when is_binary(value) do
    if Regex.match?(@positive_integer_regex, value),
      do: {:ok, value},
      else: {:error, :invalid_agent_token_id}
  end

  defp parse_token_id(_value), do: {:error, :invalid_agent_token_id}

  defp required_address(value) do
    case Evm.normalize_address(value) do
      nil -> {:error, :invalid_address}
      address -> {:ok, address}
    end
  end

  defp required_signature_type(@signature_type), do: {:ok, @signature_type}
  defp required_signature_type(_value), do: {:error, :invalid_signature_type}

  defp required_text(value, max_length)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max_length,
       do: {:ok, value}

  defp required_text(_value, _max_length), do: {:error, :invalid_pairing_request}

  defp optional_text(value, max_length)
       when is_binary(value) and byte_size(value) <= max_length do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_text(_value, _max_length), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_signed_at}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_signed_at}

  defp value(attrs, key) do
    Map.get(attrs, key)
  end

  defp signature_module do
    :autolaunch
    |> Application.get_env(:agent_pairings, [])
    |> Keyword.get(:signature_module, Siwa.EvmPersonalSign)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp short_address("0x" <> address), do: String.slice(address, 0, 6)
  defp short_address(_value), do: "account"
end
