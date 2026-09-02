defmodule Autolaunch.Privy do
  @moduledoc false

  @type session_pair :: %{access: String.t(), identity: String.t()}
  @type stage :: :configuration | :access_verification | :identity_verification | :pair_binding
  @type rejection :: {stage(), atom()}

  @callback verify_session_pair(session_pair()) ::
              {:ok, Autolaunch.VerifiedPrivyIdentity.t()} | {:error, rejection()}

  alias Autolaunch.VerifiedPrivyIdentity

  # The shared verifier's whole documented vocabulary. Any other result is a
  # shape this boundary has never reviewed, so it is reduced here rather than
  # carried into a diagnostic that might then describe a token.
  @verification_reasons [
    :invalid_verification_key,
    :token_verification_failed,
    :invalid_issuer,
    :invalid_audience,
    :token_expired,
    :token_not_yet_valid,
    :token_issued_in_future,
    :invalid_subject,
    :invalid_linked_accounts,
    :invalid_token
  ]

  @doc """
  Exchanges a Privy token pair for the signed identity evidence it proves.

  The access token authenticates the subject and session and the identity
  token carries the signed linked accounts. Each is verified independently
  against the same public key, so ordinary signed-token expiry is the whole
  freshness authority and no evidence is accepted for a subject the access
  token did not itself authenticate. Only the access token must name a
  session: Privy's identity token carries no `sid` claim of its own, and one
  it does carry anyway must name the authenticated session.

  A refusal names the boundary that refused it as `{stage, reason}`, drawn only
  from a fixed vocabulary: `:missing_privy_config` for `:configuration`, one of
  the verifier's documented reasons plus `:unknown_verification_failure` for
  `:access_verification` and `:identity_verification` with
  `:missing_session_id` for `:access_verification` alone, and
  `:subject_mismatch`, `:session_mismatch`, `:access_role_confused` or
  `:identity_accounts_missing` for `:pair_binding`.
  """
  def verify_session_pair(%{access: access, identity: identity})
      when is_binary(access) and is_binary(identity) do
    with {:ok, opts} <- verification_options(),
         {:ok, authenticated} <- verify(access, opts, :access_verification),
         {:ok, evidence} <- verify(identity, opts, :identity_verification) do
      bind(authenticated, evidence)
    end
  end

  defp verify(token, opts, stage) do
    case verifier().verify_token(token, opts) do
      {:ok, verified} -> with_session_id(verified, stage)
      {:error, reason} when reason in @verification_reasons -> {:error, {stage, reason}}
      _unreviewed -> {:error, {stage, :unknown_verification_failure}}
    end
  end

  # The mismatches are named before the roles, so whatever reaches the role
  # split authenticates this exact subject and session.
  defp bind(%{privy_user_id: did}, %{privy_user_id: other}) when did != other,
    do: {:error, {:pair_binding, :subject_mismatch}}

  defp bind(%{session_id: sid} = authenticated, evidence) do
    if names_authenticated_session?(evidence.claims, sid),
      do: bind_roles(authenticated, evidence),
      else: {:error, {:pair_binding, :session_mismatch}}
  end

  # Privy's two token roles are disjoint, and the raw claim is what separates
  # them: only an identity token carries `linked_accounts`, and the shared
  # verifier has already refused one that does not decode to a list. A decoded
  # empty list is well formed, so evidence with no wallets still binds and the
  # authority below it can invalidate the wallets it supersedes. Whatever
  # reaches the last clause authenticates this exact subject and session with
  # no signed accounts standing behind it.
  defp bind_roles(
         %{claims: authentication, privy_user_id: did, session_id: sid},
         %{claims: %{"linked_accounts" => accounts}} = evidence
       )
       when is_binary(accounts) and not is_map_key(authentication, "linked_accounts") do
    {:ok,
     %VerifiedPrivyIdentity{
       privy_user_id: did,
       session_id: sid,
       wallet_address: evidence.wallet_address,
       wallet_addresses: evidence.wallet_addresses,
       linked_socials: evidence.linked_socials
     }}
  end

  defp bind_roles(%{claims: %{"linked_accounts" => _accounts}}, _evidence),
    do: {:error, {:pair_binding, :access_role_confused}}

  defp bind_roles(_authenticated, _evidence),
    do: {:error, {:pair_binding, :identity_accounts_missing}}

  # Absence is the identity token's documented shape; a session it does name is
  # normalized exactly like the access token's before comparison, and anything
  # else standing in the claim names no session and cannot agree.
  defp names_authenticated_session?(%{"sid" => named}, session_id) when is_binary(named),
    do: String.trim(named) == session_id

  defp names_authenticated_session?(%{"sid" => _named}, _session_id), do: false
  defp names_authenticated_session?(_claims, _session_id), do: true

  defp verifier, do: Application.get_env(:autolaunch, :regent_privy_module, RegentPrivy)

  defp verification_options do
    config = Application.get_env(:autolaunch, :privy, [])

    case {config[:app_id], config[:verification_key]} do
      {app_id, key} when is_binary(app_id) and app_id != "" and is_binary(key) and key != "" ->
        clock = config[:clock] || fn -> System.system_time(:second) end
        {:ok, [app_id: app_id, verification_key: key, now: clock.()]}

      _ ->
        {:error, {:configuration, :missing_privy_config}}
    end
  end

  # Only the access token authenticates a provider session, so only it must
  # name one: Privy's identity token carries the signed accounts without a
  # `sid` claim, and whether a session it names anyway is the authenticated one
  # is pair binding's question, not this slot's.
  defp with_session_id(verified, :identity_verification), do: {:ok, verified}

  defp with_session_id(%{claims: %{"sid" => sid}} = verified, :access_verification)
       when is_binary(sid) do
    case String.trim(sid) do
      "" -> {:error, {:access_verification, :missing_session_id}}
      session_id -> {:ok, Map.put(verified, :session_id, session_id)}
    end
  end

  defp with_session_id(_verified, :access_verification),
    do: {:error, {:access_verification, :missing_session_id}}
end
