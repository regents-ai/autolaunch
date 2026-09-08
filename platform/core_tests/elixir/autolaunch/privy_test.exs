defmodule Autolaunch.PrivyTest do
  use ExUnit.Case, async: false

  alias Autolaunch.Privy

  @wallet "0x1111111111111111111111111111111111111111"

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
    Application.put_env(:autolaunch, :privy, app_id: "app", verification_keys: ["key"])
    Application.put_env(:autolaunch, :regent_privy_module, SharedVerifierStub)

    on_exit(fn ->
      restore(:privy, old_privy)
      restore(:regent_privy_module, old_verifier)
    end)
  end

  # The shared verifier itself, with disposable key pairs generated here: the
  # trusted set is the configured public keys and nothing else.
  describe "TRUSTED_KEY_SET through the shared verifier" do
    setup do
      Application.delete_env(:autolaunch, :regent_privy_module)
      [current, previous, untrusted] = for _ <- 1..3, do: JOSE.JWK.generate_key({:ec, "P-256"})
      now = System.system_time(:second)

      Application.put_env(:autolaunch, :privy,
        app_id: "app",
        verification_keys: [public_pem(current), public_pem(previous)],
        clock: fn -> now end
      )

      %{current: current, previous: previous, untrusted: untrusted, now: now}
    end

    test "a key outside the configured set signs nothing", %{
      current: current,
      untrusted: untrusted,
      now: now
    } do
      assert pair(access_token(untrusted, now), identity_token(current, now)) ==
               {:error, {:access_verification, :token_verification_failed}}

      assert pair(access_token(current, now), identity_token(untrusted, now)) ==
               {:error, {:identity_verification, :token_verification_failed}}
    end
  end

  defp public_pem(key) do
    {_kty, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    pem
  end

  defp access_token(key, now, overrides \\ %{}) do
    sign(key, %{"sub" => "did:privy:rotated", "sid" => "session", "aud" => "app"}, now, overrides)
  end

  defp identity_token(key, now, overrides \\ %{}) do
    sign(
      key,
      %{
        "sub" => "did:privy:rotated",
        "aud" => "app",
        "linked_accounts" => Jason.encode!([%{"type" => "wallet", "address" => @wallet}])
      },
      now,
      overrides
    )
  end

  defp sign(key, claims, now, overrides) do
    claims =
      claims
      |> Map.merge(%{"iss" => "privy.io", "iat" => now, "exp" => now + 300})
      |> Map.merge(overrides)

    {_alg, token} = key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact()
    token
  end

  defp pair(access, identity),
    do: Privy.verify_session_pair(%{access: access, identity: identity})

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
