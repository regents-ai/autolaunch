defmodule AutolaunchWeb.SignInWalletsTest do
  # Sean, 21 Oct 2026 (9. a): the person's own wallet is their main wallet, even
  # though Privy makes the Regents wallet during the sign-in. This signs in
  # through the site's own sign-in step, as the browser does, with tokens signed
  # as Privy signs them and checked by the real verifier.
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System

  @own "0x" <> String.duplicate("e", 40)
  @made "0x" <> String.duplicate("7", 40)

  setup do
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    privy = Application.get_env(:autolaunch, :privy, [])
    verifier = Application.fetch_env!(:autolaunch, :privy_verifier)

    Application.put_env(
      :autolaunch,
      :privy,
      privy |> Keyword.put(:app_id, "test-app") |> Keyword.put(:verification_key, pem)
    )

    Application.put_env(:autolaunch, :privy_verifier, Autolaunch.Privy)

    on_exit(fn ->
      Application.put_env(:autolaunch, :privy, privy)
      Application.put_env(:autolaunch, :privy_verifier, verifier)
    end)

    %{key: key}
  end

  test "MAIN_WALLET_STAYS_OWN: the person's own wallet stays main after Privy makes the Regents wallet",
       %{key: key} do
    sign_in(key, "did:privy:main-wallet", [wallet(@own, 4_000, "metamask")])

    sign_in(key, "did:privy:main-wallet", [
      wallet(@own, 4_000, "metamask"),
      wallet(@made, 4_001, "privy")
    ])

    {:ok, account} = Accounts.get_by_privy_did("did:privy:main-wallet", actor: %System{})

    assert account.wallet_address == @own
    assert Enum.sort(account.wallet_addresses) == Enum.sort([@own, @made])
  end

  # The browser's steps: a fresh session, then Privy's two tokens on the sign-in step.
  defp sign_in(key, did, linked_accounts) do
    csrf = build_conn() |> get("/auth/csrf")
    token = Jason.decode!(csrf.resp_body)["csrf_token"]
    proof = proof(key, did, linked_accounts)

    signed_in =
      csrf
      |> recycle()
      |> put_req_header("x-csrf-token", token)
      |> put_req_header("authorization", "Bearer " <> proof.access)
      |> put_req_header("privy-id-token", proof.identity)
      |> post("/auth/privy/session")

    assert signed_in.status == 200
  end

  defp wallet(address, verified_at, client),
    do: %{
      "type" => "wallet",
      "address" => address,
      "chain_type" => "ethereum",
      "wallet_client_type" => client,
      "lv" => verified_at
    }

  defp proof(key, did, linked_accounts) do
    now = Elixir.System.system_time(:second)

    claims = %{
      "iss" => "privy.io",
      "aud" => "test-app",
      "sub" => did,
      "iat" => now - 1,
      "exp" => now + 600,
      "sid" => did
    }

    sign = fn claims ->
      key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact() |> elem(1)
    end

    %{
      access: sign.(claims),
      identity: sign.(Map.put(claims, "linked_accounts", Jason.encode!(linked_accounts)))
    }
  end
end
