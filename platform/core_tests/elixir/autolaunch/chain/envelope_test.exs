defmodule Autolaunch.Chain.EnvelopeTest do
  use ExUnit.Case, async: false

  alias Autolaunch.Chain.Envelope

  @signer "0x1111111111111111111111111111111111111111"
  @target "0x2222222222222222222222222222222222222222"
  @data "0xabcdef"
  @context [to: @target, resource: "example", contract_name: "Example", risk_copy: "Review"]
  @validation [
    to: @target,
    signer: @signer,
    resource: "example",
    contract_name: "Example",
    action: "act"
  ]

  # A resource prepared against a deployment description carries the
  # description's binding on whatever chain it names; a subject-wallet resource
  # is Base only and carries none.
  test "a deployment-bound resource carries its binding on the chain the description names" do
    for chain_id <- [8453, 31_337] do
      binding = %{
        "rpc_url" => "http://127.0.0.1:49713",
        "chain_id" => chain_id,
        "addresses" => %{"factory" => @target}
      }

      context = [
        to: @target,
        resource: "autolaunch_launch",
        contract_name: "RegentsAutolaunchFactoryV1",
        risk_copy: "Review",
        chain_id: chain_id,
        lab_binding: binding
      ]

      envelope = Envelope.new("autolaunch_launch", @signer, @data, context)

      assert envelope.chain_id == chain_id
      assert envelope.metadata.lab == binding
      assert Envelope.valid?(envelope, resource: "autolaunch_launch", chain_id: chain_id)
      refute Envelope.valid?(envelope, resource: "autolaunch_launch", chain_id: chain_id + 1)

      for invalid <- [
            Keyword.delete(context, :lab_binding),
            Keyword.replace!(context, :resource, "autolaunch_subject_wallet")
          ] do
        assert_raise ArgumentError, ~r/network context/, fn ->
          Envelope.new("autolaunch_launch", @signer, @data, invalid)
        end
      end
    end

    subject = Envelope.new("autolaunch_subject_wallet", @signer, @data, @context)
    assert subject.chain_id == 8453
    assert is_nil(subject.metadata.lab)

    assert_raise ArgumentError, ~r/network context/, fn ->
      Envelope.new("autolaunch_subject_wallet", @signer, @data, @context ++ [chain_id: 31_337])
    end
  end

  test "rejects target and signer drift" do
    envelope = Envelope.new("act", @signer, @data, @context)
    assert Envelope.valid?(envelope, @validation)
    refute Envelope.valid?(envelope, Keyword.replace!(@validation, :to, @signer))

    refute Envelope.valid?(
             %{envelope | expected_signer: @target},
             @validation
           )
  end

  test "binds validation to the expected action" do
    envelope = Envelope.new("act", @signer, @data, @context)
    refute Envelope.valid?(envelope, Keyword.replace!(@validation, :action, "other"))

    refute Envelope.valid_for_confirmation?(
             envelope,
             Keyword.replace!(@validation, :action, "other")
           )
  end

  # A durable submitted hash has to stay verifiable once its signing window
  # closes, or a launch that really is on Base could never be told the truth
  # about. Only the resources that own a durable operation are on that list.
  test "an expired launch envelope is no longer sendable but is still confirmable" do
    old = DateTime.utc_now() |> DateTime.add(-601, :second)
    previous = Application.get_env(:autolaunch, :wallet_action_clock)
    Application.put_env(:autolaunch, :wallet_action_clock, fn -> old end)

    launch =
      Envelope.new("autolaunch_launch", @signer, @data, launch_context())
      |> legacy_envelope()

    other = Envelope.new("act", @signer, @data, @context)

    Application.put_env(:autolaunch, :wallet_action_clock, fn -> DateTime.utc_now() end)
    on_exit(fn -> restore(:wallet_action_clock, previous) end)

    refute Envelope.valid?(launch, resource: "autolaunch_launch")
    assert Envelope.valid_for_confirmation?(launch, resource: "autolaunch_launch")

    # A resource that owns no durable operation is not confirmable after expiry.
    refute Envelope.valid_for_confirmation?(other, @validation)
  end

  defp launch_context do
    [
      to: @target,
      resource: "autolaunch_launch",
      contract_name: "RegentsAutolaunchFactoryV1",
      risk_copy: "Review",
      chain_id: 8453,
      lab_binding: %{
        "rpc_url" => "https://base.example.test",
        "chain_id" => 8453,
        "addresses" => %{"factory" => @target}
      }
    ]
  end

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)

  defp legacy_envelope(envelope) do
    legacy_id =
      [
        envelope.resource,
        envelope.action,
        envelope.chain_id,
        envelope.to,
        envelope.value,
        envelope.data,
        envelope.expected_signer,
        envelope.prepared_at
      ]
      |> Enum.map_join(":", &to_string/1)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    envelope
    |> Map.delete(:preparation_nonce)
    |> Map.put(:action_id, legacy_id)
    |> Map.put(:idempotency_key, legacy_id)
    |> resign()
  end

  defp resign(envelope) do
    payload =
      envelope
      |> Map.take([
        :action_id,
        :idempotency_key,
        :resource,
        :action,
        :chain_id,
        :to,
        :value,
        :data,
        :expected_signer,
        :prepared_at,
        :preparation_nonce,
        :expires_at,
        :risk_copy,
        :approval,
        :arguments,
        :metadata
      ])
      |> Jason.encode!()
      |> Jason.decode!()

    Map.put(
      envelope,
      :confirmation_token,
      Phoenix.Token.sign(AutolaunchWeb.Endpoint, "wallet-action", payload)
    )
  end
end
