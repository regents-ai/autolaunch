defmodule AutolaunchWeb.PublicNameTest do
  # A person's Public Display Name lives in the shared profile every Regent site
  # reads (`RegentIdentity.HTTP` at /api/v1/profile). It is read and changed for
  # the person signed in on this site, from its pages, or for the person an agent
  # they paired acts for (`AutolaunchWeb.Plugs.ProfileOwner`), and for nobody
  # else. People sign in through the site's own sign-in step with the fixture
  # verifier's tokens; the sign-in service is stood in for and vouches for the
  # agent's wallet.
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestPrivyVerifier

  @moduletag :capture_log
  @agent "0x" <> String.duplicate("2", 40)

  setup do
    privy = Application.get_env(:autolaunch, :privy, [])
    # The fixture verifier's sign-ins name this Privy app, so the profile the
    # sign-in makes is the one the page and the API read.
    Application.put_env(:autolaunch, :privy, Keyword.put(privy, :app_id, "autolaunch-fixture"))
    on_exit(fn -> Application.put_env(:autolaunch, :privy, privy) end)

    test = self()

    Req.Test.stub(RegentAgents.Broker, fn broker ->
      {:ok, body, broker} = Plug.Conn.read_body(broker)
      payload = Jason.decode!(body)
      send(test, {:verified, payload})

      Req.Test.json(broker, %{
        "code" => "http_envelope_valid",
        "data" => %{
          "verified" => true,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => payload["headers"]["x-agent-wallet-address"],
            "chain_id" => 8453,
            "audience" => "autolaunch"
          },
          "agentRegistration" => nil,
          "agentBook" => nil
        }
      })
    end)

    :ok
  end

  test "the person signed in here reads and sets their name, a change only with the forms token" do
    {signed_in, token} = sign_in("valid")
    assert read(signed_in)["display_name"] == nil

    # Without the forms token a change counts as signed out and changes nothing.
    refused = send_json(signed_in, %{display_name: "Mallory"}, nil)
    assert json_response(refused, 401)["error"]["code"] == "authentication_required"
    assert read(signed_in)["display_name"] == nil

    saved = send_json(signed_in, %{display_name: "Ada Lovelace"}, token)
    assert json_response(saved, 200)["profile"]["display_name"] == "Ada Lovelace"
    assert read(signed_in)["display_name"] == "Ada Lovelace"

    html = signed_in |> recycle() |> get("/account") |> html_response(200)
    assert html =~ ~s(value="Ada Lovelace")
  end

  test "with no sign-in nothing is read or changed" do
    for {method, body} <- [{:get, nil}, {:patch, Jason.encode!(%{display_name: "Mallory"})}] do
      refused =
        build_conn()
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, "/api/v1/profile", body)

      assert json_response(refused, 401)["error"]["code"] == "authentication_required"
    end
  end

  test "a paired agent reads and sets its person's name, which reads back for that person and nobody else" do
    # An agent paired with no one acts for no one.
    assert json_response(agent(:get), 403)["error"]["code"] == "agent_not_paired"

    {person, _token} = sign_in("valid")
    {someone_else, _token} = sign_in("other-account")
    pair("did:privy:verified")

    assert json_response(agent(:get), 200)["profile"]["display_name"] == nil

    body = Jason.encode!(%{display_name: "Named by my agent"})
    saved = agent(:patch, body)
    assert json_response(saved, 200)["profile"]["display_name"] == "Named by my agent"

    # The sign-in service checked the exact body the agent signed.
    assert_received {:verified, %{"method" => "PATCH", "body_digest" => digest}}
    assert digest == Siwa.content_digest_for_body(body)

    assert read(person)["display_name"] == "Named by my agent"
    assert read(someone_else)["display_name"] == nil
  end

  defp read(signed_in),
    do:
      signed_in
      |> recycle()
      |> get("/api/v1/profile")
      |> json_response(200)
      |> Map.fetch!("profile")

  # Phoenix's test connection skips the forms token check; these requests keep
  # it, as a browser's do.
  defp send_json(signed_in, body, token) do
    conn =
      signed_in
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "x-csrf-token", token), else: conn
    dispatch(conn, @endpoint, :patch, "/api/v1/profile", Jason.encode!(body))
  end

  # The agent's request, signed with its wallet.
  defp agent(method, body \\ nil) do
    conn = put_req_header(build_conn(), "x-agent-wallet-address", @agent)

    conn =
      if body,
        do: put_req_header(conn, "content-type", "application/json"),
        else: conn

    dispatch(conn, @endpoint, method, "/api/v1/profile", body)
  end

  defp pair(privy_user_id) do
    code =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: privy_user_id})

    RegentAgents.pair_agent!(code.code, "Fixture", :codex,
      actor: %RegentAgents.Agent{wallet: @agent}
    )
  end

  # The browser's steps: a fresh session, then Privy's two tokens on the sign-in
  # step, then the forms token the site's pages carry for the session that step left.
  defp sign_in(access) do
    csrf = build_conn() |> get("/auth/csrf")

    signed_in =
      csrf
      |> recycle()
      |> put_req_header("x-csrf-token", Jason.decode!(csrf.resp_body)["csrf_token"])
      |> put_req_header("authorization", "Bearer " <> access)
      |> put_req_header("privy-id-token", TestPrivyVerifier.identity_token(access))
      |> post("/auth/privy/session")

    assert signed_in.status == 200
    page = signed_in |> recycle() |> get("/auth/csrf")
    {page, json_response(page, 200)["csrf_token"]}
  end
end
