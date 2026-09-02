defmodule Autolaunch.TestPrivyVerifier do
  @moduledoc false

  @identity_suffix "-identity"

  @doc """
  The identity token deterministically paired with `access_token`.

  Real Privy access and identity tokens are distinct strings with distinct
  roles, so the fixtures are too. `test/browser/support/authenticated_privy.ts`
  builds the same partner for the acceptance browsers and has to stay in step
  with this.
  """
  def identity_token(access_token), do: access_token <> @identity_suffix

  @doc """
  The session exchange the controller performs.

  Only an access token names a session and only its own partner is that
  session's signed evidence, so a swapped, reused or unpaired token is no pair
  at all and never reaches the session boundary. Refusals carry the same tagged
  classification `Autolaunch.Privy` returns.
  """
  def verify_session_pair(%{access: access, identity: identity})
      when is_binary(access) and is_binary(identity) do
    access |> verify_access_token() |> paired(identity == identity_token(access))
  end

  defp paired({:ok, verified}, true), do: {:ok, verified}
  defp paired({:ok, _verified}, false), do: {:error, {:pair_binding, :session_mismatch}}
  defp paired({:error, reason}, _matched), do: {:error, {:access_verification, reason}}

  def verify_access_token("valid") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "browser-session",
       privy_user_id: "did:privy:verified",
       wallet_address: "0x1111111111111111111111111111111111111111",
       wallet_addresses: ["0x1111111111111111111111111111111111111111"]
     }}
  end

  def verify_access_token("no-wallet") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "browser-session",
       privy_user_id: "did:privy:verified",
       wallet_address: nil,
       wallet_addresses: []
     }}
  end

  def verify_access_token("changed-wallet") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "browser-session",
       privy_user_id: "did:privy:verified",
       wallet_address: "0x2222222222222222222222222222222222222222",
       wallet_addresses: ["0x2222222222222222222222222222222222222222"]
     }}
  end

  def verify_access_token("other-account") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "other-browser-session",
       privy_user_id: "did:privy:other",
       wallet_address: "0x3333333333333333333333333333333333333333",
       wallet_addresses: ["0x3333333333333333333333333333333333333333"]
     }}
  end

  def verify_access_token("valid-staking") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "staking-browser-session",
       privy_user_id: "did:privy:staking-browser",
       wallet_address: "0x1111111111111111111111111111111111111111",
       wallet_addresses: ["0x1111111111111111111111111111111111111111"]
     }}
  end

  def verify_access_token("valid-redemption") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "redemption-browser-session",
       privy_user_id: "did:privy:redemption-browser",
       wallet_address: "0x1111111111111111111111111111111111111111",
       wallet_addresses: ["0x1111111111111111111111111111111111111111"]
     }}
  end

  def verify_access_token("valid-autolaunch-draft") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "autolaunch-draft-browser-session",
       privy_user_id: "did:privy:autolaunch-draft-browser",
       wallet_address: "0x3333333333333333333333333333333333333333",
       wallet_addresses: ["0x3333333333333333333333333333333333333333"]
     }}
  end

  def verify_access_token("valid-formation-cloud") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "formation-cloud-browser-session",
       privy_user_id: "did:privy:formation-cloud-browser",
       wallet_address: "0x4444444444444444444444444444444444444444",
       wallet_addresses: ["0x4444444444444444444444444444444444444444"]
     }}
  end

  def verify_access_token("conflicting-social") do
    {:ok,
     %Autolaunch.VerifiedPrivyIdentity{
       session_id: "conflicting-social-session",
       privy_user_id: "did:privy:conflicting-social",
       wallet_address: "0x5555555555555555555555555555555555555555",
       wallet_addresses: ["0x5555555555555555555555555555555555555555"],
       linked_socials: [
         %{
           provider: :x,
           subject: "shared-x-subject",
           username: "other",
           display_name: nil
         }
       ]
     }}
  end

  # The access token is well-formed for this app but its own verification is
  # refused, which is the one refusal a fresh provider login can clear. The
  # catch-all below is the generic refusal, so both live in the same stage.
  def verify_access_token("stale-access"), do: {:error, :token_verification_failed}

  def verify_access_token(_token), do: {:error, :invalid_token}
end
