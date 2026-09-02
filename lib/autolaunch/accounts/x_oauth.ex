defmodule Autolaunch.Accounts.XOAuth do
  @moduledoc """
  Short-lived X Authorization Code + PKCE coordination for a verified session.

  OAuth credentials never leave the callback. The database stores only the
  temporary state and verifier needed to finish one popup plus the verified
  public identity returned by X.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.{SessionAuthority, XConnection}
  alias Autolaunch.Actors.Human

  @roles [:profile, :company]
  @attempt_ttl 600
  @max_intent_sequence 9_007_199_254_740_991
  @scope "tweet.read users.read"

  @type role :: :profile | :company

  @spec enabled?() :: boolean()
  def enabled?, do: match?({:ok, _client_id}, client_id())

  @spec origin() :: String.t()
  def origin, do: AutolaunchWeb.Endpoint.url()

  @spec callback_url() :: String.t()
  def callback_url, do: origin() <> "/auth/x/callback"

  @spec begin(SessionAuthority.claim() | nil, String.t() | atom(), map()) ::
          {:ok, %{url: String.t(), role: role(), generation: String.t()}} | {:error, term()}
  def begin(claim, role, intent_params) do
    with {:ok, role} <- role(role),
         {:ok, intent} <- intent(intent_params),
         {:ok, config} <- config(),
         {:ok, %{url: url, session_params: params}} <- strategy().authorize_url(config),
         {:ok, state} <- required_binary(params, :state),
         {:ok, verifier} <- required_binary(params, :code_verifier),
         {:ok, generation} <- attempt_generation(claim, state) do
      attrs = %{
        role: role,
        attempt_state: state,
        attempt_verifier: verifier,
        attempt_generation: generation,
        attempt_expires_at: DateTime.add(now(), @attempt_ttl, :second),
        intent_sequence: intent.sequence,
        intent_generation: intent.generation
      }

      case SessionAuthority.transact_exact(claim, &persist_attempt(&1, role, attrs)) do
        {:ok, _connection} -> {:ok, %{url: url, role: role, generation: generation}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec callback(SessionAuthority.claim() | nil, map()) ::
          {:ok, %{role: role(), generation: String.t()}}
          | {:error, term()}
          | {:error, term(), %{role: role(), generation: String.t()}}
  def callback(claim, %{"state" => state} = params) when is_binary(state) do
    with {:ok, generation} <- attempt_generation(claim, state),
         {:ok, attempt} <- preflight(claim, state, generation) do
      result =
        with {:ok, config} <- config(),
             callback_config =
               Keyword.put(config, :session_params, %{
                 state: attempt.state,
                 code_verifier: attempt.verifier
               }),
             {:ok, %{user: response}} <- provider_callback(callback_config, params),
             {:ok, identity} <- identity(response),
             {:ok, _connection} <- finish(claim, attempt, identity) do
          {:ok, %{role: attempt.role, generation: attempt.generation}}
        end

      case result do
        {:ok, _payload} = success ->
          success

        {:error, reason} ->
          clear_attempt(claim, attempt)
          {:error, reason, %{role: attempt.role, generation: attempt.generation}}
      end
    end
  end

  def callback(_claim, _params), do: {:error, :invalid_callback}

  @spec disconnect(SessionAuthority.claim() | nil, String.t() | atom(), map()) ::
          {:ok, %{role: role(), generation: String.t()}} | {:error, term()}
  def disconnect(claim, role, intent_params) do
    with {:ok, role} <- role(role),
         {:ok, intent} <- intent(intent_params) do
      mutate_intent(claim, role, intent, :disconnect)
    end
  end

  @spec cancel(SessionAuthority.claim() | nil, String.t() | atom(), map()) ::
          {:ok, %{role: role(), generation: String.t()}} | {:error, term()}
  def cancel(claim, role, intent_params) do
    with {:ok, role} <- role(role),
         {:ok, intent} <- intent(intent_params),
         true <- is_binary(intent.cancel_generation),
         true <- is_integer(intent.cancel_sequence),
         true <- intent.cancel_sequence < intent.sequence do
      mutate_intent(claim, role, intent, :cancel)
    else
      false -> {:error, :invalid_intent}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_for_account(Ash.Resource.record()) :: {:ok, list()} | {:error, term()}
  def list_for_account(account) do
    actor = actor(account)

    with {:ok, connections} <- Accounts.list_my_x_connections(actor: actor),
         {:ok, changed?} <- cleanup_expired_attempts(connections, actor) do
      if changed?,
        do: Accounts.list_my_x_connections(actor: actor),
        else: {:ok, connections}
    end
  end

  @spec public_for_humans([integer()]) :: {:ok, list()} | {:error, term()}
  def public_for_humans(ids) do
    ids = ids |> Enum.filter(&is_integer/1) |> Enum.uniq()
    if ids == [], do: {:ok, []}, else: Accounts.list_public_x_connections(ids)
  end

  defp persist_attempt(account, role, attrs) do
    actor = actor(account)

    case Accounts.get_my_x_connection_for_update(role, actor: actor) do
      {:ok, nil} ->
        Accounts.begin_x_connection_attempt(attrs, actor: actor)

      {:ok, connection} ->
        if attrs.intent_sequence > intent_sequence(connection) do
          Accounts.replace_x_connection_attempt(
            connection,
            Map.delete(attrs, :role),
            actor: actor
          )
        else
          {:error, :stale_intent}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mutate_intent(claim, role, intent, action) do
    case SessionAuthority.transact_exact(
           claim,
           &mutate_intent_account(&1, role, intent, action)
         ) do
      {:ok, _connection} -> {:ok, %{role: role, generation: intent.generation}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mutate_intent_account(account, role, intent, action) do
    actor = actor(account)

    case Accounts.get_my_x_connection_for_update(role, actor: actor) do
      {:ok, nil} ->
        Accounts.record_x_connection_intent(
          %{role: role, intent_sequence: intent.sequence, intent_generation: intent.generation},
          actor: actor
        )

      {:ok, connection} ->
        if valid_intent_transition?(connection, intent, action),
          do: apply_intent_action(connection, intent, action, actor),
          else: {:error, :stale_intent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_intent_action(connection, intent, :cancel, actor) do
    Accounts.cancel_x_connection_attempt(
      connection,
      intent.sequence,
      intent.generation,
      actor: actor
    )
  end

  defp apply_intent_action(connection, intent, :disconnect, actor) do
    Accounts.disconnect_x_connection(
      connection,
      intent.sequence,
      intent.generation,
      actor: actor
    )
  end

  defp valid_intent_transition?(connection, intent, :disconnect),
    do: intent.sequence > intent_sequence(connection)

  defp valid_intent_transition?(connection, intent, :cancel) do
    current_sequence = intent_sequence(connection)

    (current_sequence < intent.cancel_sequence or
       (current_sequence == intent.cancel_sequence and
          connection.intent_generation == intent.cancel_generation)) and
      intent.sequence > current_sequence
  end

  defp cleanup_expired_attempts(connections, actor) do
    candidates = connections |> Enum.filter(&expired_attempt?/1) |> Enum.take(length(@roles))

    case Enum.reduce_while(candidates, :ok, &cleanup_expired_candidate(&1, actor, &2)) do
      :ok -> {:ok, candidates != []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_expired_candidate(connection, actor, :ok) do
    case clear_expired_attempt(connection, actor) do
      {:ok, _cleared?} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp clear_expired_attempt(connection, actor) do
    snapshot = attempt_snapshot(connection)
    observe_expired_cleanup(snapshot)

    Ash.DataLayer.transaction(XConnection, fn ->
      clear_expired_attempt_transaction(connection.role, snapshot, actor)
    end)
  end

  defp clear_expired_attempt_transaction(role, snapshot, actor) do
    case Accounts.get_my_x_connection_for_update(role, actor: actor) do
      {:ok, %XConnection{} = locked} ->
        case maybe_clear_expired_attempt(locked, snapshot, actor) do
          {:ok, cleared?} -> cleared?
          {:error, reason} -> Ash.DataLayer.rollback(XConnection, reason)
        end

      {:ok, nil} ->
        false

      {:error, reason} ->
        Ash.DataLayer.rollback(XConnection, reason)
    end
  end

  defp maybe_clear_expired_attempt(locked, snapshot, actor) do
    if same_attempt?(locked, snapshot) and expired_attempt?(locked) do
      case Accounts.clear_x_connection_attempt(locked, actor: actor) do
        {:ok, _cleared} -> {:ok, true}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, false}
    end
  end

  defp preflight(claim, state, generation) do
    case SessionAuthority.transact_exact(claim, &preflight_account(&1, state, generation)) do
      {:ok, {:active, attempt}} -> {:ok, attempt}
      {:ok, :expired} -> {:error, :invalid_or_expired_attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight_account(account, state, generation) do
    actor = actor(account)

    with {:ok, connections} <- Accounts.list_my_x_connections(actor: actor) do
      connections
      |> Enum.find(&state_matches?(&1, state))
      |> preflight_connection(actor, generation)
    end
  end

  defp preflight_connection(%XConnection{} = connection, actor, generation) do
    attempt = attempt_snapshot(connection)

    if active?(connection) and connection.attempt_generation == generation,
      do: {:ok, {:active, attempt}},
      else: expire_attempt(connection, attempt, actor)
  end

  defp preflight_connection(_missing, _actor, _generation),
    do: {:error, :invalid_or_expired_attempt}

  defp expire_attempt(connection, attempt, actor) do
    with {:ok, locked} <-
           Accounts.get_my_x_connection_for_update(connection.role, actor: actor),
         true <- same_attempt?(locked, attempt),
         {:ok, _cleared} <- Accounts.clear_x_connection_attempt(locked, actor: actor) do
      {:ok, :expired}
    else
      _stale -> {:ok, :expired}
    end
  end

  defp finish(claim, attempt, identity) do
    SessionAuthority.transact_exact(claim, fn account ->
      actor = actor(account)

      with {:ok, %XConnection{} = connection} <-
             Accounts.get_my_x_connection_for_update(attempt.role, actor: actor),
           true <- same_attempt?(connection, attempt),
           true <- active?(connection) do
        Accounts.complete_x_connection_attempt(
          connection,
          identity
          |> Map.put(:verified_at, now())
          |> Map.put(:next_generation, Ash.UUID.generate()),
          actor: actor
        )
      else
        _stale -> {:error, :stale_attempt}
      end
    end)
  end

  defp clear_attempt(claim, attempt) do
    SessionAuthority.transact_exact(claim, fn account ->
      actor = actor(account)

      with {:ok, %XConnection{} = connection} <-
             Accounts.get_my_x_connection_for_update(attempt.role, actor: actor),
           true <- same_attempt?(connection, attempt),
           {:ok, connection} <- Accounts.clear_x_connection_attempt(connection, actor: actor) do
        {:ok, connection}
      else
        _stale -> {:ok, nil}
      end
    end)
  end

  defp provider_callback(config, params) do
    strategy().callback(config, params)
  rescue
    _error -> {:error, :provider_failure}
  catch
    _kind, _reason -> {:error, :provider_failure}
  end

  defp config do
    with {:ok, client_id} <- client_id() do
      {:ok,
       [
         client_id: client_id,
         base_url: "https://api.x.com",
         authorize_url: "https://x.com/i/oauth2/authorize",
         token_url: "https://api.x.com/2/oauth2/token",
         user_url: "https://api.x.com/2/users/me?user.fields=profile_image_url,name,username",
         redirect_uri: callback_url(),
         authorization_params: [scope: @scope],
         code_verifier: true
       ]}
    end
  end

  defp client_id do
    case Application.get_env(:autolaunch, :x_oauth_client_id) do
      client_id when is_binary(client_id) ->
        case String.trim(client_id) do
          "" -> {:error, :x_oauth_disabled}
          client_id -> {:ok, client_id}
        end

      _missing ->
        {:error, :x_oauth_disabled}
    end
  end

  defp identity(%{"data" => data}) when is_map(data), do: identity(data)

  defp identity(%{"id" => id, "username" => username} = user)
       when is_binary(id) and is_binary(username) do
    with {:ok, id} <- bounded(id, 64),
         {:ok, username} <- bounded(username, 64),
         {:ok, display_name} <- optional_bounded(user["name"], 100),
         {:ok, avatar_url} <- optional_https_url(user["profile_image_url"]) do
      {:ok,
       %{
         x_user_id: id,
         username: username,
         display_name: display_name,
         avatar_url: avatar_url
       }}
    end
  end

  defp identity(_response), do: {:error, :invalid_x_identity}

  defp bounded(value, max) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.valid?(value) and byte_size(value) <= max,
      do: {:ok, value},
      else: {:error, :invalid_x_identity}
  end

  defp optional_bounded(nil, _max), do: {:ok, nil}
  defp optional_bounded(value, max), do: bounded(value, max)

  defp optional_https_url(nil), do: {:ok, nil}

  defp optional_https_url(value) when is_binary(value) do
    with {:ok, value} <- bounded(value, 500),
         %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) <- URI.parse(value) do
      {:ok, value}
    else
      _invalid -> {:error, :invalid_x_identity}
    end
  end

  defp optional_https_url(_value), do: {:error, :invalid_x_identity}

  defp role(role) when role in @roles, do: {:ok, role}
  defp role("profile"), do: {:ok, :profile}
  defp role("company"), do: {:ok, :company}
  defp role(_role), do: {:error, :invalid_role}

  defp required_binary(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :invalid_oauth_attempt}
    end
  end

  defp intent(params) when is_map(params) do
    params = stringify_atom_keys(params)
    sequence = params["intent_sequence"]
    generation = params["intent_generation"]
    cancel_generation = params["cancel_generation"]
    cancel_sequence = params["cancel_sequence"]

    with true <- is_integer(sequence) and sequence > 0 and sequence <= @max_intent_sequence,
         {:ok, generation} <- Ecto.UUID.cast(generation),
         {:ok, cancel_generation} <- optional_uuid(cancel_generation),
         true <- is_nil(cancel_sequence) or valid_intent_sequence?(cancel_sequence) do
      {:ok,
       %{
         sequence: sequence,
         generation: generation,
         cancel_generation: cancel_generation,
         cancel_sequence: cancel_sequence
       }}
    else
      _invalid -> {:error, :invalid_intent}
    end
  end

  defp intent(_params), do: {:error, :invalid_intent}

  defp stringify_atom_keys(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: Ecto.UUID.cast(value)

  defp valid_intent_sequence?(sequence),
    do: is_integer(sequence) and sequence > 0 and sequence <= @max_intent_sequence

  defp intent_sequence(%{intent_sequence: sequence}) when is_integer(sequence), do: sequence
  defp intent_sequence(_connection), do: 0

  defp attempt_generation(%{lineage: lineage, generation: generation}, state)
       when is_binary(lineage) and is_integer(generation) and generation >= 0 and is_binary(state) do
    digest =
      :crypto.hash(
        :sha256,
        [
          "ash-platform:x-oauth-attempt:v1",
          <<0>>,
          lineage,
          <<0>>,
          Integer.to_string(generation),
          <<0>>,
          state
        ]
      )

    {:ok, digest |> binary_part(0, 16) |> Ecto.UUID.load!()}
  end

  defp attempt_generation(_claim, _state), do: {:error, :stale_authority}

  defp state_matches?(%{attempt_state: expected}, provided)
       when is_binary(expected) and is_binary(provided) and
              byte_size(expected) == byte_size(provided),
       do: Plug.Crypto.secure_compare(expected, provided)

  defp state_matches?(_connection, _provided), do: false

  defp active?(%{attempt_expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(expires_at, now()) == :gt

  defp active?(_connection), do: false

  defp expired_attempt?(%{attempt_generation: generation, attempt_expires_at: %DateTime{} = at})
       when is_binary(generation),
       do: DateTime.compare(at, now()) != :gt

  defp expired_attempt?(_connection), do: false

  defp same_attempt?(connection, attempt) do
    connection.role == attempt.role and
      connection.attempt_generation == attempt.generation and
      connection.attempt_verifier == attempt.verifier and
      state_matches?(connection, attempt.state)
  end

  defp attempt_snapshot(connection) do
    %{
      role: connection.role,
      state: connection.attempt_state,
      verifier: connection.attempt_verifier,
      generation: connection.attempt_generation
    }
  end

  defp observe_expired_cleanup(snapshot) do
    case Application.get_env(:autolaunch, :x_oauth_expired_cleanup_observer) do
      observer when is_function(observer, 1) ->
        observer.(%{role: snapshot.role, generation: snapshot.generation})

      _disabled ->
        :ok
    end
  end

  defp actor(account), do: %Human{human_account_id: account.id}
  defp now, do: clock().()
  defp clock, do: Application.get_env(:autolaunch, :x_oauth_clock, &DateTime.utc_now/0)

  defp strategy,
    do: Application.get_env(:autolaunch, :x_oauth_strategy, Assent.Strategy.OAuth2)
end
