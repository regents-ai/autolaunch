defmodule AutolaunchWeb.Api.AgentPairingControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @human_wallet "0x1111111111111111111111111111111111111111"
  @registry_address "0x3333333333333333333333333333333333333333"

  setup do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:agent-pairing-controller", %{
        "wallet_address" => @human_wallet,
        "wallet_addresses" => [@human_wallet],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "signed-in browser creates and reads a pairing session", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    create_conn = post(conn, "/v1/app/agent-pairings", %{})

    assert %{
             "ok" => true,
             "session" => %{
               "session_id" => session_id,
               "status" => "pending",
               "pairing_code" => pairing_code,
               "challenge_message" => challenge_message
             }
           } = json_response(create_conn, 201)

    assert pairing_code =~ ~r/^AL-[A-Z2-9]{6}-[A-Z2-9]{8}$/
    assert is_binary(challenge_message)

    read_conn =
      create_conn
      |> recycle()
      |> init_test_session(privy_user_id: human.privy_user_id)
      |> get("/v1/app/agent-pairings/#{session_id}")

    assert %{
             "ok" => true,
             "session" => %{
               "session_id" => ^session_id,
               "status" => "pending",
               "pairing_code" => nil
             }
           } = json_response(read_conn, 200)
  end

  test "local agent completes a pairing session with a wallet signature", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    create_conn = post(conn, "/v1/app/agent-pairings", %{})
    %{"session" => session} = json_response(create_conn, 201)
    evidence = signed_evidence(session["challenge_message"])

    complete_conn =
      post(conn, "/v1/app/agent-pairings/complete", %{
        "pairing_code" => session["pairing_code"],
        "challenge_message" => session["challenge_message"],
        "agent_wallet_address" => evidence.address,
        "agent_chain_id" => 84_532,
        "agent_registry_address" => @registry_address,
        "agent_token_id" => "42",
        "agent_label" => "Atlas Agent",
        "signature_type" => "evm_personal_sign",
        "signature" => evidence.signature,
        "signed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    assert %{
             "ok" => true,
             "session" => %{
               "status" => "completed",
               "pairing_code" => nil,
               "agent" => %{
                 "agent_wallet_address" => address,
                 "agent_chain_id" => 84_532,
                 "agent_registry_address" => @registry_address,
                 "agent_token_id" => "42",
                 "agent_label" => "Atlas Agent"
               }
             }
           } = json_response(complete_conn, 200)

    assert address == evidence.address
  end

  test "browser pairing creation requires a signed-in user", %{conn: conn} do
    conn = post(conn, "/v1/app/agent-pairings", %{})

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(conn, 401)
  end

  defp signed_evidence(message) do
    digest = Siwa.EvmPersonalSign.personal_hash(message)
    private_key = test_private_key()
    {:ok, {signature, recovery_id}} = ExSecp256k1.sign_compact(digest, private_key)
    {:ok, public_key} = ExSecp256k1.create_public_key(private_key)
    address = Siwa.EvmPersonalSign.public_key_to_address(public_key)

    %{
      address: address,
      signature: "0x" <> Base.encode16(signature <> <<recovery_id + 27>>, case: :lower)
    }
  end

  defp test_private_key do
    :crypto.strong_rand_bytes(32)
  end
end
