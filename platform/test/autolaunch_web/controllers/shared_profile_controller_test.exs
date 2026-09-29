defmodule AutolaunchWeb.SharedProfileControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  setup_all do
    database = Autolaunch.Repo.config()[:database]

    unless database == "autolaunch" <> System.fetch_env!("MIX_TEST_PARTITION") <> "_test",
      do: raise("Profile tests require the prepared disposable database")

    RegentIdentity.Migrator.up(Autolaunch.Repo)
    assert RegentIdentity.Migrator.up(Autolaunch.Repo) == []
    :ok
  end

  setup do
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    previous = Application.get_env(:autolaunch, :privy)
    Application.put_env(:autolaunch, :privy, app_id: "profile-fixture", verification_key: public)
    on_exit(fn -> Application.put_env(:autolaunch, :privy, previous || []) end)
    %{key: key}
  end

  test "profile page and private API use shared components and signed ownership", %{key: key} do
    html = build_conn() |> get("/profile") |> html_response(200)
    assert html =~ "data-regent-profile"
    assert html =~ "Connect X"
    assert build_conn() |> get("/api/v1/profile") |> response(401)

    assert build_conn()
           |> init_test_session(%{profile_id: "forged"})
           |> get("/api/v1/profile")
           |> response(401)

    pair = pair(key, "alice")
    assert api(:get, "/api/v1/profile", pair).status == 404
    created = api(:post, "/api/v1/profile/sync", pair)
    assert created.status == 200
    profile = json_response(created, 200)["profile"]
    assert profile["x"]["verified"]
    assert profile["x"]["username"] == "alice"
    refute Map.has_key?(profile, "privy_user_id")
    assert api(:get, "/api/v1/profile", pair(key, "bob")).status == 404
    updated = api(:patch, "/api/v1/profile", pair, %{display_name: "Shared name"})
    assert json_response(updated, 200)["profile"]["profile_id"] == profile["profile_id"]
    assert json_response(updated, 200)["profile"]["display_name"] == "Shared name"
  end

  test "profile verifies a rotated proof pair with the same trusted key set", %{key: key} do
    rotated = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, public} = rotated |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    config = Application.get_env(:autolaunch, :privy)

    Application.put_env(
      :autolaunch,
      :privy,
      Keyword.put(config, :verification_keys, [config[:verification_key], public])
    )

    original = pair(key, "rotated-profile")
    replacement = pair(rotated, "rotated-profile")
    proof = %{original | identity: replacement.identity}
    assert api(:post, "/api/v1/profile/sync", proof).status == 200
    assert api(:get, "/api/v1/profile", proof).status == 200

    substituted = %{original | identity: pair(rotated, "not-the-owner").identity}
    assert api(:get, "/api/v1/profile", substituted).status == 401
    assert api(:get, "/api/v1/profile", proof).status == 200
  end

  defp api(method, path, pair, body \\ nil) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{pair.access}")
    |> put_req_header("privy-id-token", pair.identity)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, if(body, do: Jason.encode!(body), else: nil))
  end

  defp pair(key, subject) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "privy.io",
      "aud" => "profile-fixture",
      "sub" => subject,
      "iat" => now - 1,
      "exp" => now + 600
    }

    sign = fn claims ->
      {_, token} = key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact()
      token
    end

    accounts = [
      %{
        type: "wallet",
        chain_type: "ethereum",
        address: "0x1111111111111111111111111111111111111111"
      },
      %{type: "twitter_oauth", subject: "x-#{subject}", username: subject}
    ]

    %{
      access: sign.(Map.put(claims, "sid", "fixture-session")),
      identity: sign.(Map.put(claims, "linked_accounts", Jason.encode!(accounts)))
    }
  end
end
