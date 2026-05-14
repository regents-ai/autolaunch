defmodule Autolaunch.AgentPairingsTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.AgentPairings
  alias Autolaunch.AgentPairings.Session

  @human_wallet "0x1111111111111111111111111111111111111111"
  @registry_address "0x3333333333333333333333333333333333333333"

  test "creates a pending session with a display code and stores only the hash" do
    human = human!("create")

    assert {:ok, session} = AgentPairings.create_session(human)
    assert session.status == "pending"
    assert session.pairing_code =~ ~r/^AL-[A-Z2-9]{6}-[A-Z2-9]{8}$/
    assert session.challenge_message == AgentPairings.challenge_message(session.challenge_nonce)

    stored = Repo.get_by!(Session, session_id: session.session_id)
    assert stored.pairing_code_hash != session.pairing_code
    assert stored.pairing_code_hash =~ ~r/^[0-9a-f]{64}$/
    assert stored.status == "pending"
  end

  test "completes a pending session once and resolves the human by agent claims" do
    human = human!("complete")
    {:ok, session} = AgentPairings.create_session(human)
    evidence = signed_evidence(session)

    assert {:ok, completed} =
             AgentPairings.complete_session(%{
               "pairing_code" => session.pairing_code,
               "challenge_message" => session.challenge_message,
               "agent_wallet_address" => evidence.address,
               "agent_chain_id" => 8_453,
               "agent_registry_address" => @registry_address,
               "agent_token_id" => "42",
               "agent_label" => "Atlas Agent",
               "signature_type" => "evm_personal_sign",
               "signature" => evidence.signature,
               "signed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             })

    assert completed.status == "completed"
    assert completed.agent.agent_wallet_address == evidence.address
    assert completed.agent.agent_chain_id == 8_453
    assert completed.agent.agent_registry_address == @registry_address
    assert completed.agent.agent_token_id == "42"
    assert completed.agent.agent_label == "Atlas Agent"
    assert completed.pairing_code == nil

    assert [%{name: "Atlas Agent", access_mode: "paired", state: "connected"}] =
             AgentPairings.list_connected_agent_cards(human)

    assert %Autolaunch.Accounts.HumanUser{id: human_id} =
             AgentPairings.get_human_by_agent_claims(%{
               "wallet_address" => evidence.address,
               "chain_id" => "8453",
               "registry_address" => @registry_address,
               "token_id" => "42"
             })

    assert human_id == human.id

    assert {:error, :pairing_completed} =
             AgentPairings.complete_session(%{
               "pairing_code" => session.pairing_code,
               "challenge_message" => session.challenge_message,
               "agent_wallet_address" => evidence.address,
               "agent_chain_id" => 8_453,
               "agent_registry_address" => @registry_address,
               "agent_token_id" => "42",
               "signature_type" => "evm_personal_sign",
               "signature" => evidence.signature,
               "signed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             })
  end

  test "rejects expired pairing codes" do
    human = human!("expired")
    {:ok, session} = AgentPairings.create_session(human)
    evidence = signed_evidence(session)

    Repo.get_by!(Session, session_id: session.session_id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :pairing_expired} =
             AgentPairings.complete_session(%{
               "pairing_code" => session.pairing_code,
               "challenge_message" => session.challenge_message,
               "agent_wallet_address" => evidence.address,
               "agent_chain_id" => 8_453,
               "agent_registry_address" => @registry_address,
               "agent_token_id" => "43",
               "signature_type" => "evm_personal_sign",
               "signature" => evidence.signature,
               "signed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             })

    assert {:ok, %{status: "expired"}} = AgentPairings.get_session(human, session.session_id)
  end

  test "rejects signatures that do not match the submitted wallet" do
    human = human!("bad-signature")
    {:ok, session} = AgentPairings.create_session(human)
    evidence = signed_evidence(session)

    assert {:error, :invalid_signature} =
             AgentPairings.complete_session(%{
               "pairing_code" => session.pairing_code,
               "challenge_message" => session.challenge_message,
               "agent_wallet_address" => "0x2222222222222222222222222222222222222222",
               "agent_chain_id" => 8_453,
               "agent_registry_address" => @registry_address,
               "agent_token_id" => "44",
               "signature_type" => "evm_personal_sign",
               "signature" => evidence.signature,
               "signed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             })
  end

  defp human!(suffix) do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:pairings-#{suffix}", %{
        "wallet_address" => @human_wallet,
        "wallet_addresses" => [@human_wallet],
        "display_name" => "Operator #{suffix}"
      })

    human
  end

  defp signed_evidence(%{challenge_message: message}) do
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
