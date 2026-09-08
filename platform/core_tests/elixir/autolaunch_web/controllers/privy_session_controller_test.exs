defmodule AutolaunchWeb.PrivySessionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  alias Autolaunch.Actors.System

  @identity Autolaunch.TestPrivyVerifier.identity_token("valid")

  # The one rendered diagnostic line; this repository's development formatter
  # drops metadata, so the whole classification lives in the message.

  test "COMPLETE_PAIR_REQUIRED: a half, blank, duplicated or unverifiable pair is refused before a write",
       %{conn: conn} do
    assert {:ok, before_attempts} =
             Accounts.get_by_privy_did("did:privy:verified", actor: %System{})

    headers = [
      # Neither token alone is a pair, and neither may be blank.
      [],
      [{"authorization", "Bearer valid"}],
      [{"privy-id-token", @identity}],
      [{"authorization", "Bearer  "}, {"privy-id-token", @identity}],
      [{"authorization", "Bearer valid"}, {"privy-id-token", "  "}],
      # A second identity header is a client choosing which evidence counts.
      [
        {"authorization", "Bearer valid"},
        {"privy-id-token", @identity},
        {"privy-id-token", @identity}
      ],
      # Role confusion in either slot, and the same token reused in both.
      [{"authorization", "Bearer #{@identity}"}, {"privy-id-token", "valid"}],
      [{"authorization", "Bearer valid"}, {"privy-id-token", "valid"}],
      [{"authorization", "Bearer #{@identity}"}, {"privy-id-token", @identity}],
      # Evidence signed for a different session is evidence for no session here.
      [
        {"authorization", "Bearer valid"},
        {"privy-id-token", Autolaunch.TestPrivyVerifier.identity_token("other-account")}
      ],
      # Neither token verifies at all.
      [
        {"authorization", "Bearer invalid"},
        {"privy-id-token", Autolaunch.TestPrivyVerifier.identity_token("invalid")}
      ]
    ]

    for pair <- headers do
      refused =
        conn
        |> init_test_session(%{})
        |> put_valid_csrf()
        |> put_headers(pair)
        |> post("/auth/privy/session", %{})

      assert json_response(refused, 401) == %{"error" => "unauthorized"}
      assert_no_token_disclosure(refused)
    end

    assert {:ok, after_attempts} =
             Accounts.get_by_privy_did("did:privy:verified", actor: %System{})

    assert account_evidence(after_attempts) == account_evidence(before_attempts)
  end

  # Raises the primary Logger level for one case, because this repository logs at
  # warning under test and the diagnostic is deliberately debug-level. Every case
  # in this synchronous file runs alone, so nothing else observes the change.

  defp put_privy_pair(conn, access_token) do
    conn
    |> put_req_header("authorization", "Bearer #{access_token}")
    |> put_req_header(
      "privy-id-token",
      Autolaunch.TestPrivyVerifier.identity_token(access_token)
    )
  end

  # Carries the headers exactly as given, so a duplicated one travels the way a
  # client would actually send it.
  defp put_headers(conn, headers), do: %{conn | req_headers: conn.req_headers ++ headers}

  # Neither token may come back as a token on anything the page or a log can
  # read. The match is bounded so an unrelated word that merely spells one of
  # them inside itself, such as `must-revalidate`, is not read as a disclosure.
  # The session cookie is opaque ciphertext carrying no request header, and its
  # contents are pinned by `CANONICAL_AUTHORITY_ROW`.
  defp assert_no_token_disclosure(conn) do
    observable =
      conn.resp_headers
      |> Enum.reject(fn {name, _value} -> name == "set-cookie" end)
      |> Enum.map_join("\n", fn {name, value} -> "#{name}: #{value}" end)

    for surface <- [observable, conn.resp_body], secret <- ["valid", @identity] do
      refute surface =~ ~r/\b#{Regex.escape(secret)}\b/
    end
  end

  test "CSRF is required for both session creation and deletion", %{conn: conn} do
    assert_error_sent 403, fn ->
      conn
      |> init_test_session(%{})
      |> enforce_csrf()
      |> put_privy_pair("valid")
      |> post("/auth/privy/session", %{})
    end

    assert_error_sent 403, fn ->
      conn
      |> init_test_session(%{})
      |> enforce_csrf()
      |> delete("/auth/privy/session")
    end
  end

  # A browser that reached signed-in state through the real HTTP flow, so its
  # session travels only as a cookie and no test-side write marks it dirty.

  # A browser holding `session` in a genuinely signed cookie rather than in the
  # test process, so the response's own cookie decision is what is observed.

  # What the browser does after a renewing response: adopt the rotated token.

  # Restores the release budget this file's bound is specified in, and hands the
  # limiter back the way the next case expects to find it. Every case that spends
  # the budget lives in this synchronous file, so no reset can race an admission.

  # A cookie-less browser whose peer address is `peer`, carrying `headers`
  # exactly as given so a duplicated or forged address header travels the way a
  # client would actually send it.

  # Spends one client's whole budget and returns its next, denied, response.

  # Carries the response's own cookie into the next request the way a browser
  # does, without losing the connect info a mount needs.

  defp put_valid_csrf(conn) do
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> enforce_csrf()
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> put_req_header("x-csrf-token", token)
  end

  defp enforce_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp account_evidence(nil), do: nil

  defp account_evidence(account),
    do:
      Map.take(account, [:id, :privy_user_id, :wallet_address, :wallet_addresses, :display_name])
end
