defmodule AutolaunchWeb.PrivySessionController do
  use AutolaunchWeb, :controller

  alias Autolaunch.AccessContext
  alias Autolaunch.Accounts.BootstrapRateLimiter
  alias Autolaunch.Accounts.{SessionAuthority, VerifiedSession}
  alias Autolaunch.Privy

  require Logger

  @account_evidence_reasons [:missing_linked_wallet, :invalid_verified_identity]

  @doc """
  The browser-session state matrix.

  A browser with no claim is bootstrapped onto a fresh unbound lineage; an exact
  claim is only observed; a superseded or unrecoverable one is told which of the
  two it is instead of being silently reset.

  Observation writes no session, so this response carries no `Set-Cookie` and a
  delayed one cannot put an older generation back over a later winner's cookie.

  Only a browser carrying no claim can create a lineage, so only that request
  spends the anonymous bootstrap budget, and it spends it before `renew/1` can
  insert a row: a denial therefore leaves behind no `SessionAuthority` lineage
  and no CSRF session state.
  """
  def csrf(conn, _params), do: admit_bootstrap(conn, claim(conn))

  def create(conn, _untrusted_params) do
    with {:ok, pair} <- session_pair(conn),
         {:ok, verified} <- verifier().verify_session_pair(pair),
         {:ok, account, identity_conflicts} <- establish(verified) do
      bind(conn, account, identity_conflicts)
    else
      {:error, {stage, reason}} -> refuse(conn, stage, reason)
    end
  end

  def show(conn, _params), do: json(conn, session_payload(conn.assigns.current_human_account))

  def delete(conn, _params) do
    topic = SessionAuthority.revoke(claim(conn))

    %Plug.Conn{state: :sent} = conn = conn |> drop_session() |> json(%{ok: true})

    broadcast_disconnect(topic)
    conn
  end

  @doc """
  The one place a request turns a cookie into an account.

  The cookie names no account, so identity comes from the locked row and only
  after the claim is exactly current. Anything else — missing, malformed,
  superseded, revoked or absent authority, or an account whose verified evidence
  has lapsed — leaves the request anonymous.
  """
  def enforce_authority(conn) do
    {lineage, account} = conn |> claim() |> SessionAuthority.resolve()

    conn |> assign(:current_lineage, lineage) |> assign(:current_human_account, account)
  end

  defp admit_bootstrap(conn, nil) do
    budget = Application.fetch_env!(:autolaunch, :session_bootstrap_rate_limit)
    window = Keyword.fetch!(budget, :window_seconds)
    {key, source} = client_key(conn)

    case BootstrapRateLimiter.admit(
           {:session_bootstrap, key},
           Keyword.fetch!(budget, :limit),
           window
         ) do
      :ok -> renew(conn, nil)
      {:error, :rate_limited} -> rate_limited(conn, source, window)
    end
  end

  defp admit_bootstrap(conn, claim), do: renew(conn, claim)

  defp renew(conn, claim) do
    case SessionAuthority.renew(claim) do
      {:bootstrap, claim} -> conn |> rotate_session(claim) |> issue_token()
      {:current, _claim} -> issue_token(conn)
      {:error, :superseded} -> lifecycle_error(conn, "session_superseded")
      {:error, :reset} -> conn |> drop_session() |> lifecycle_error("session_reset_required")
    end
  end

  defp rate_limited(conn, source, window) do
    :telemetry.execute([:autolaunch, :session_bootstrap, :rate_limited], %{count: 1}, %{
      source: source
    })

    conn
    |> put_resp_header("retry-after", to_string(window))
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:too_many_requests)
    |> json(%{error: "rate_limited"})
  end

  # Fly terminates the connection, so the peer is the proxy and the client
  # address arrives in one header the proxy sets itself. Anything but exactly one
  # parseable value keys the proxy-wide peer bucket rather than a second header a
  # client could forge itself a private budget with.
  defp client_key(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [value] -> parsed(value, conn.remote_ip)
      _absent_or_duplicated -> {normalized(conn.remote_ip), :peer_fallback}
    end
  end

  defp parsed(value, remote_ip) do
    case value |> :binary.bin_to_list() |> :inet.parse_strict_address() do
      {:ok, address} -> {normalized(address), :client_header}
      {:error, :einval} -> {normalized(remote_ip), :peer_fallback}
    end
  end

  # The mapped and compatible IPv6 spellings of one IPv4 address share its
  # bucket, and a genuine IPv6 client is keyed by its /64 so one host cannot
  # spend the budget once per address in the block it was handed. The key is
  # never persisted, rendered or logged; it lives only in the limiter.
  defp normalized({_, _, _, _} = ipv4), do: ipv4

  defp normalized({0, 0, 0, 0, 0, embedding, high, low}) when embedding in [0, 0xFFFF] do
    <<a, b, c, d>> = <<high::16, low::16>>
    {a, b, c, d}
  end

  defp normalized({a, b, c, d, _, _, _, _}), do: {a, b, c, d, 0, 0, 0, 0}

  # Privy is verified before the row lock, so only the transition itself is
  # serialized. A different account is a two-step cutover: this response revokes
  # and disconnects the old lineage and binds nothing.
  defp bind(conn, account, identity_conflicts) do
    case SessionAuthority.sign_in(claim(conn), account.id) do
      {:ok, transition, claim} ->
        conn
        |> rotate_session(claim)
        |> put_identity_conflict_header(identity_conflicts)
        |> put_resp_header("x-autolaunch-session-changed", to_string(transition == :bind))
        |> json(session_payload(account))

      {:switch, topic} ->
        conn = conn |> drop_session() |> lifecycle_error("account_switch_required")
        broadcast_disconnect(topic)
        conn

      {:error, :superseded} ->
        lifecycle_error(conn, "session_superseded")

      {:error, :reset} ->
        conn |> drop_session() |> lifecycle_error("session_reset_required")
    end
  end

  # The account boundary's own two outcomes are named; anything else it or Ash
  # returns is reduced without being inspected, so no query, changeset or record
  # detail can reach the classification.
  defp establish(verified) do
    case VerifiedSession.establish(verified) do
      {:ok, _account, _conflicts} = established -> established
      {:error, reason} when reason in @account_evidence_reasons -> account_evidence(reason)
      _rejected -> account_evidence(:account_rejected)
    end
  end

  defp account_evidence(reason), do: {:error, {:account_evidence, reason}}

  # Both values are fixed atoms from the classification contract, and the
  # development formatter drops metadata, so they belong in the message itself.
  # The refused pair is never interpolated, inspected or answered differently.
  defp refuse(conn, stage, reason) do
    Logger.debug("Privy session rejected stage=#{stage} reason=#{reason}")
    conn |> mark_recoverable(stage, reason) |> unauthorized()
  end

  # The one refusal a browser may answer with a fresh provider login: the access
  # token itself did not verify, so the provider session behind it is spent. The
  # marker names nothing about the refusal, and every other refusal carries none,
  # so no other 401 can end a provider session.
  defp mark_recoverable(conn, :access_verification, :token_verification_failed),
    do: put_resp_header(conn, "x-autolaunch-provider-relogin", "allowed")

  defp mark_recoverable(conn, _stage, _reason), do: conn

  # The provider attempt is over before any authority work starts, so no external
  # call sits inside the transaction: a bearer this browser cannot prove revokes
  # the lineage it was offered for instead of leaving it bound and current.
  defp unauthorized(conn) do
    topic = SessionAuthority.revoke(claim(conn))

    %Plug.Conn{state: :sent} =
      conn = conn |> drop_session() |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

    broadcast_disconnect(topic)
    conn
  end

  defp claim(conn), do: conn |> get_session() |> SessionAuthority.claim()

  defp rotate_session(conn, claim) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_claim(claim)
    |> put_csrf_state()
  end

  defp put_claim(conn, claim) do
    claim
    |> SessionAuthority.session()
    |> Enum.reduce(conn, fn {key, value}, conn -> put_session(conn, key, value) end)
  end

  defp put_csrf_state(conn) do
    Plug.CSRFProtection.get_csrf_token()
    put_session(conn, "_csrf_token", Plug.CSRFProtection.dump_state())
  end

  defp issue_token(conn), do: json(conn, %{csrf_token: Plug.CSRFProtection.get_csrf_token()})

  defp lifecycle_error(conn, error), do: conn |> put_status(:conflict) |> json(%{error: error})

  defp drop_session(conn), do: configure_session(conn, drop: true)

  defp verifier, do: Application.get_env(:autolaunch, :privy_verifier, Privy)

  defp session_payload(nil),
    do: %{
      authenticated: false,
      account_control: %{
        kind: :sign_in,
        label: "Sign In",
        profile_path: nil,
        avatar_data_uri: nil
      }
    }

  defp session_payload(account) do
    access_context = AccessContext.human(account)
    control = AccessContext.account_control(access_context)

    %{
      authenticated: true,
      account_control: %{
        kind: control.kind,
        label: control.label,
        profile_path: control.profile_path,
        settings_path: control.settings_path,
        avatar_data_uri: control.avatar_data_uri
      }
    }
  end

  defp broadcast_disconnect(nil), do: :ok

  defp broadcast_disconnect(topic),
    do: AutolaunchWeb.Endpoint.broadcast(topic, "disconnect", %{})

  defp put_identity_conflict_header(conn, []), do: conn

  defp put_identity_conflict_header(conn, _conflicts),
    do: put_resp_header(conn, "x-autolaunch-identity-error", "already-connected")

  # The access token travels only as the bearer and the identity token only as
  # Privy's own header, so neither reaches a URL, a body or a log. Exactly one
  # of each is a pair; anything else is refused before the provider is asked.
  defp session_pair(conn) do
    with {:ok, access} <- bearer_token(conn),
         {:ok, identity} <- identity_token(conn) do
      {:ok, %{access: access, identity: identity}}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> access] -> present(access, :missing_access_token)
      _absent_or_duplicated -> {:error, {:request_pair, :missing_access_token}}
    end
  end

  defp identity_token(conn) do
    case get_req_header(conn, "privy-id-token") do
      [identity] -> present(identity, :missing_identity_token)
      _absent_or_duplicated -> {:error, {:request_pair, :missing_identity_token}}
    end
  end

  defp present(token, reason) do
    case String.trim(token) do
      "" -> {:error, {:request_pair, reason}}
      token -> {:ok, token}
    end
  end
end
