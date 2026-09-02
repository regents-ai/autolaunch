defmodule Autolaunch.PrivyTest do
  use ExUnit.Case, async: false

  alias Autolaunch.Privy

  @wallet "0x1111111111111111111111111111111111111111"
  @social %{
    provider: :github,
    subject: "github-user-7",
    username: "regents-ai",
    display_name: nil
  }

  @verification_failures %{
    "forged" => :token_verification_failed,
    "expired" => :token_expired,
    "wrong-app" => :invalid_audience,
    "wrong-issuer" => :invalid_issuer,
    "malformed" => :invalid_token
  }

  # The real provider's roles: an access token authenticates the subject and
  # session and carries no linked accounts, while its identity token repeats
  # only the subject and carries the signed accounts as a JSON string — a real
  # identity token names no `sid` of its own.
  defmodule SharedVerifierStub do
    @wallet "0x1111111111111111111111111111111111111111"

    @linked_accounts Jason.encode!([
                       %{"type" => "wallet", "address" => @wallet},
                       %{
                         "type" => "github_oauth",
                         "subject" => "github-user-7",
                         "username" => "regents-ai"
                       }
                     ])

    def verify_token(token, _opts), do: verified(token)

    defp verified("access"), do: session(%{"sub" => "did:privy:test", "sid" => "session"})

    defp verified("identity"),
      do: session(%{"sub" => "did:privy:test", "linked_accounts" => @linked_accounts})

    defp verified("identity-without-wallets"),
      do: session(%{"sub" => "did:privy:test", "linked_accounts" => Jason.encode!([])})

    # The docs-inconsistent variants that do name a session: agreement binds,
    # and any other value in the claim is a refusal.
    defp verified("identity-with-session"),
      do:
        session(%{
          "sub" => "did:privy:test",
          "sid" => "session",
          "linked_accounts" => @linked_accounts
        })

    defp verified("identity-other-session"),
      do:
        session(%{
          "sub" => "did:privy:test",
          "sid" => "other-session",
          "linked_accounts" => @linked_accounts
        })

    defp verified("identity-blank-session"),
      do:
        session(%{
          "sub" => "did:privy:test",
          "sid" => "   ",
          "linked_accounts" => @linked_accounts
        })

    defp verified("access-other-subject"),
      do: session(%{"sub" => "did:privy:other", "sid" => "session"})

    defp verified("identity-other-subject"),
      do: session(%{"sub" => "did:privy:other", "linked_accounts" => @linked_accounts})

    defp verified("access-other-session"),
      do: session(%{"sub" => "did:privy:test", "sid" => "other-session"})

    defp verified("access-blank-sid"),
      do: session(%{"sub" => "did:privy:test", "sid" => "   "})

    # The shared verifier refuses a `linked_accounts` string that does not
    # decode to a list before it ever returns claims.
    defp verified("identity-malformed-accounts"), do: {:error, :invalid_linked_accounts}

    defp verified("expired"), do: {:error, :token_expired}
    defp verified("wrong-app"), do: {:error, :invalid_audience}
    defp verified("wrong-issuer"), do: {:error, :invalid_issuer}
    defp verified("forged"), do: {:error, :token_verification_failed}

    # A result outside the shared verifier's documented vocabulary, carrying a
    # detail no classification may ever repeat.
    defp verified("unreviewed"), do: {:error, %RuntimeError{message: "leaky detail"}}

    defp verified(_malformed), do: {:error, :invalid_token}

    defp session(claims) do
      {:ok,
       %{
         claims: claims,
         privy_user_id: claims["sub"],
         wallet_address: wallet_address(claims),
         wallet_addresses: wallet_addresses(claims),
         linked_socials: linked_socials(claims)
       }}
    end

    defp wallet_address(claims), do: claims |> wallet_addresses() |> List.first()

    defp wallet_addresses(%{"linked_accounts" => @linked_accounts}), do: [@wallet]
    defp wallet_addresses(_claims), do: []

    defp linked_socials(%{"linked_accounts" => @linked_accounts}),
      do: [
        %{
          provider: :github,
          subject: "github-user-7",
          username: "regents-ai",
          display_name: nil
        }
      ]

    defp linked_socials(_claims), do: []
  end

  setup do
    old_privy = Application.get_env(:autolaunch, :privy)
    old_verifier = Application.get_env(:autolaunch, :regent_privy_module)
    Application.put_env(:autolaunch, :privy, app_id: "app", verification_key: "key")
    Application.put_env(:autolaunch, :regent_privy_module, SharedVerifierStub)

    on_exit(fn ->
      restore(:privy, old_privy)
      restore(:regent_privy_module, old_verifier)
    end)
  end

  test "SIGNED_EVIDENCE_ONLY: a matching pair yields the identity token's evidence" do
    assert {:ok,
            %Autolaunch.VerifiedPrivyIdentity{
              privy_user_id: "did:privy:test",
              session_id: "session",
              wallet_address: @wallet,
              wallet_addresses: [@wallet],
              linked_socials: [@social]
            }} = pair("access", "identity")
  end

  test "SIGNED_EVIDENCE_ONLY: identity evidence with no wallets still reaches the boundary" do
    assert {:ok,
            %Autolaunch.VerifiedPrivyIdentity{
              privy_user_id: "did:privy:test",
              session_id: "session",
              wallet_address: nil,
              wallet_addresses: [],
              linked_socials: []
            }} = pair("access", "identity-without-wallets")
  end

  test "MUTUALLY_EXCLUSIVE_TOKEN_ROLES: each slot accepts only its own token role" do
    # An access token carries no signed accounts, so it is never evidence, and
    # an identity token never authenticates a session on its own: a real one
    # names no session at all, and one that repeats it is refused by role.
    assert pair("access", "access") == {:error, {:pair_binding, :identity_accounts_missing}}
    assert pair("identity", "access") == {:error, {:access_verification, :missing_session_id}}
    assert pair("identity", "identity") == {:error, {:access_verification, :missing_session_id}}

    assert pair("identity-with-session", "access") ==
             {:error, {:pair_binding, :access_role_confused}}

    assert pair("identity-with-session", "identity") ==
             {:error, {:pair_binding, :access_role_confused}}
  end

  test "INDEPENDENT_VERIFICATION_AND_BINDING: evidence binds only to the authenticated subject" do
    assert pair("access", "identity-other-subject") ==
             {:error, {:pair_binding, :subject_mismatch}}

    assert pair("access-other-subject", "identity") ==
             {:error, {:pair_binding, :subject_mismatch}}
  end

  test "INDEPENDENT_VERIFICATION_AND_BINDING: an identity token may repeat only the authenticated session" do
    assert {:ok, %Autolaunch.VerifiedPrivyIdentity{session_id: "session"}} =
             pair("access", "identity-with-session")

    assert pair("access", "identity-other-session") ==
             {:error, {:pair_binding, :session_mismatch}}

    assert pair("access-other-session", "identity-with-session") ==
             {:error, {:pair_binding, :session_mismatch}}

    assert pair("access", "identity-blank-session") ==
             {:error, {:pair_binding, :session_mismatch}}
  end

  test "INDEPENDENT_VERIFICATION_AND_BINDING: an access token that names no session is refused" do
    assert pair("access-blank-sid", "identity") ==
             {:error, {:access_verification, :missing_session_id}}
  end

  test "INDEPENDENT_VERIFICATION_AND_BINDING: either slot's own verification failure names its stage" do
    for {unverifiable, reason} <- @verification_failures do
      assert pair(unverifiable, "identity") == {:error, {:access_verification, reason}}
      assert pair("access", unverifiable) == {:error, {:identity_verification, reason}}
    end
  end

  test "MUTUALLY_EXCLUSIVE_TOKEN_ROLES: malformed signed accounts are not evidence" do
    assert pair("access", "identity-malformed-accounts") ==
             {:error, {:identity_verification, :invalid_linked_accounts}}
  end

  test "REDACTED_CLASSIFICATION: an unreviewed verifier result is reduced, never repeated" do
    assert pair("unreviewed", "identity") ==
             {:error, {:access_verification, :unknown_verification_failure}}

    assert pair("access", "unreviewed") ==
             {:error, {:identity_verification, :unknown_verification_failure}}
  end

  test "FAIL_CLOSED: an unconfigured verification key refuses every pair" do
    Application.delete_env(:autolaunch, :privy)

    assert pair("access", "identity") == {:error, {:configuration, :missing_privy_config}}
  end

  defp pair(access, identity),
    do: Privy.verify_session_pair(%{access: access, identity: identity})

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
