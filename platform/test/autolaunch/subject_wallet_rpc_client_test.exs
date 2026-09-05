defmodule Autolaunch.SubjectWalletRpcClientTest do
  @moduledoc """
  The release client: fail-closed preparation, and receipts that are evidence
  rather than success by themselves.
  """

  use ExUnit.Case, async: false

  alias Autolaunch.BaseRpcStub
  alias Autolaunch.Chain.{Abi, SubjectAbi}
  alias Autolaunch.{SubjectWalletChainClient, SubjectWalletRpcClient}

  @client_key :autolaunch_subject_wallet_http_client
  @signer "0x1111111111111111111111111111111111111111"
  @splitter "0x2222222222222222222222222222222222222222"
  @receiver "0x3333333333333333333333333333333333333333"
  @token "0x4444444444444444444444444444444444444444"
  @reference "0x" <> String.duplicate("7e", 32)
  @hash "0x" <> String.duplicate("ab", 32)
  @safe_block "0x20"

  describe "PRODUCTION_STAYS_FAIL_CLOSED: the release default prepares nothing" do
    test "the release default is the client, with no test override installed" do
      # This test deliberately installs no override, so the module the lane
      # resolves is the one production would use.
      refute Application.get_env(:autolaunch, :autolaunch_subject_wallet_chain_client)
      assert SubjectWalletChainClient.module() == SubjectWalletRpcClient
    end

    test "preparation refuses before any provider is contacted" do
      # No HTTP client is installed at all, so any provider read would raise
      # rather than answer. The refusal happens first.
      Application.delete_env(:autolaunch, @client_key)

      assert SubjectWalletRpcClient.snapshot(%{
               splitter: @splitter,
               receiver: @receiver,
               signer: @signer,
               token: @token,
               spender: @splitter
             }) == {:error, :subject_wallet_preparation_unavailable}
    end
  end

  describe "RECEIPT_IS_EVIDENCE: only canonical state and this action's own logs settle it" do
    test "a receipt above the safe head stays pending rather than becoming an answer" do
      envelope = envelope(:unstake)
      install(envelope, :action, receipt_block: "0x99", logs: [staked_log()])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :pending}}
    end

    test "a receipt in a block that is no longer canonical stays pending" do
      envelope = envelope(:unstake)
      install(envelope, :action, logs: [unstaked_log()], moved: true)

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :pending}}
    end

    test "a canonical revert is terminal reverted" do
      envelope = envelope(:unstake)
      install(envelope, :action, status: "0x0", logs: [])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :reverted}}
    end

    test "a provider that cannot answer is a retryable read, never a settlement" do
      envelope = envelope(:unstake)
      BaseRpcStub.install(@client_key, fn _data, _state -> :unavailable end)
      BaseRpcStub.put(%{chain_id: :unavailable})

      assert {:error, :chain_unavailable} =
               SubjectWalletRpcClient.verify(envelope, :action, @hash)
    end

    test "an unstake needs exactly its own event, for this signer and this amount" do
      envelope = envelope(:unstake)

      install(envelope, :action, logs: [unstaked_log()])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :confirmed}}

      install(envelope, :action, logs: [staked_log()])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :unverified}}

      install(envelope, :action, logs: [])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :unverified}}
    end

    test "a claim with no event at all is a truthful confirmed no-op" do
      envelope = envelope(:claim)
      install(envelope, :action, logs: [])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :confirmed, result: %{"claimed" => %{}}}}
    end

    test "a claim adopts the amount its own event reports" do
      envelope = envelope(:claim)
      install(envelope, :action, logs: [claimed_log(@token, 42)])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :confirmed, result: %{"claimed" => %{@token => "42"}}}}
    end

    test "a claim whose event names a different token is unverified" do
      envelope = envelope(:claim)
      install(envelope, :action, logs: [claimed_log(usdc(), 42)])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :unverified}}
    end

    test "claim-all accepts one to three unique positive claims and none at all" do
      envelope = envelope(:claim_all)

      install(envelope, :action,
        logs: [claimed_log(@token, 1), claimed_log(usdc(), 2), claimed_log(regent(), 3)]
      )

      assert {:ok, %{outcome: :confirmed, result: %{"claimed" => claimed}}} =
               SubjectWalletRpcClient.verify(envelope, :action, @hash)

      assert claimed == %{@token => "1", usdc() => "2", regent() => "3"}

      install(envelope, :action, logs: [])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :confirmed, result: %{"claimed" => %{}}}}

      # A duplicate token is a contradiction, not a larger claim.
      install(envelope, :action, logs: [claimed_log(@token, 1), claimed_log(@token, 2)])

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :unverified}}
    end

    test "a payment must route exactly the reviewed gross with no referral" do
      envelope = envelope(:pay)

      install(envelope, :action, logs: [routed_log(100, 0, 100)])

      assert {:ok, %{outcome: :confirmed, result: %{"gross" => "100"}}} =
               SubjectWalletRpcClient.verify(envelope, :action, @hash)

      for contradiction <- [routed_log(99, 0, 99), routed_log(100, 1, 99), routed_log(100, 0, 99)] do
        install(envelope, :action, logs: [contradiction])

        assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
                 {:ok, %{outcome: :unverified}}
      end
    end

    test "a sweep adopts the amount its own event reports, whatever the review showed" do
      envelope = envelope(:sweep)
      install(envelope, :action, logs: [routed_log(250, 0, 250)])

      assert {:ok, %{outcome: :confirmed, result: result}} =
               SubjectWalletRpcClient.verify(envelope, :action, @hash)

      # The review showed the balance at preparation time; the event supplies what
      # actually moved.
      assert result["gross"] == "250"
      assert envelope["arguments"]["amount_atomic"] == "100"
    end

    test "the exact note event is authority and a receipt-block read only corroborates it" do
      envelope = envelope(:set_note)

      # The note has already moved on in the same block, and the exact event this
      # transaction emitted still confirms it.
      later = "0x" <> String.duplicate("cd", 32)

      install(envelope, :action,
        logs: [note_log(@reference)],
        calls: fn _data, _state -> later end
      )

      assert {:ok, %{outcome: :confirmed, result: result}} =
               SubjectWalletRpcClient.verify(envelope, :action, @hash)

      assert result["reviewed_note"] == @reference
      assert result["note"] == later

      # Without its own event, there is nothing to corroborate.
      install(envelope, :action, logs: [], calls: fn _data, _state -> @reference end)

      assert SubjectWalletRpcClient.verify(envelope, :action, @hash) ==
               {:ok, %{outcome: :unverified}}
    end
  end

  describe "APPROVAL_NEEDS_ITS_EVENT_AND_ITS_ALLOWANCE" do
    test "the exact event and a receipt-block allowance that supports it both hold" do
      envelope = envelope(:stake)

      install(envelope, :approval,
        logs: [approval_log(50)],
        calls: fn _data, _state -> BaseRpcStub.uint(50) end
      )

      assert SubjectWalletRpcClient.verify(envelope, :approval, @hash) ==
               {:ok, %{outcome: :confirmed}}
    end

    test "an approval whose own event is missing never advances the sequence" do
      envelope = envelope(:stake)
      install(envelope, :approval, logs: [], calls: fn _data, _state -> BaseRpcStub.uint(50) end)

      assert SubjectWalletRpcClient.verify(envelope, :approval, @hash) ==
               {:ok, %{outcome: :unverified}}
    end

    test "an allowance that no longer supports the reviewed amount is unverified" do
      envelope = envelope(:stake)

      install(envelope, :approval,
        logs: [approval_log(50)],
        calls: fn _data, _state -> BaseRpcStub.uint(49) end
      )

      assert SubjectWalletRpcClient.verify(envelope, :approval, @hash) ==
               {:ok, %{outcome: :unverified}}
    end

    test "every allowance read is pinned to the receipt's own canonical block" do
      envelope = envelope(:stake)

      install(envelope, :approval,
        logs: [approval_log(50)],
        calls: fn _data, _state -> BaseRpcStub.uint(50) end
      )

      assert {:ok, _confirmed} = SubjectWalletRpcClient.verify(envelope, :approval, @hash)

      assert BaseRpcStub.call_blocks() == [
               %{blockHash: BaseRpcStub.safe_hash(), requireCanonical: true}
             ]
    end
  end

  # Envelopes and logs

  defp usdc, do: String.downcase(Abi.usdc_address())
  defp regent, do: String.downcase(Abi.regent_address())

  defp envelope(kind) do
    %{
      "expected_signer" => @signer,
      "to" => target(kind),
      "arguments" => %{
        "kind" => Atom.to_string(kind),
        "splitter" => @splitter,
        "receiver" => @receiver,
        "token" => @token,
        "amount_atomic" => "100",
        "payment_reference" => @reference,
        "note" => @reference,
        "bound_tokens" => %{"subject" => @token, "usdc" => usdc(), "regent" => regent()},
        "steps" => steps(kind)
      }
    }
  end

  defp steps(:stake),
    do: [
      %{
        "step" => "approval",
        "to" => @token,
        "spender" => @splitter,
        "amount" => "50",
        "data" => Abi.encode_erc20("approve", [@splitter, 50])
      },
      %{"step" => "action", "to" => @splitter, "data" => SubjectAbi.encode_stake(100)}
    ]

  defp steps(kind), do: [%{"step" => "action", "to" => target(kind), "data" => data(kind)}]

  defp data(:unstake), do: SubjectAbi.encode_unstake(100)
  defp data(:claim), do: SubjectAbi.encode_claim(@token)
  defp data(:claim_all), do: SubjectAbi.encode_claim_all()
  defp data(:pay), do: SubjectAbi.encode_pay(@token, 100, @reference)
  defp data(:sweep), do: SubjectAbi.encode_sweep(@token, @reference)
  defp data(:set_note), do: SubjectAbi.encode_set_receiver_note(@reference)

  defp target(kind) when kind in [:pay, :sweep, :set_note], do: @receiver
  defp target(_splitter_kind), do: @splitter

  # The stub answers about exactly one transaction: the step's own target and
  # calldata, mined into a canonical block at or below the safe head.
  defp install(envelope, step, options) do
    logs = Keyword.get(options, :logs, [])
    status = Keyword.get(options, :status, "0x1")
    block = Keyword.get(options, :receipt_block, @safe_block)
    calls = Keyword.get(options, :calls, fn _data, _state -> BaseRpcStub.uint(0) end)

    BaseRpcStub.install(@client_key, calls)

    BaseRpcStub.put(%{
      receipts: %{@hash => BaseRpcStub.receipt(@hash, block, logs, status)},
      transactions: %{@hash => transaction(envelope, step)},
      blocks: moved_blocks(Keyword.get(options, :moved, false), block)
    })
  end

  # The observed transaction really is the step under test: its own target, its
  # own reviewed calldata, this signer and zero value.
  defp transaction(envelope, step) do
    current = Atom.to_string(step)

    %{"to" => to, "data" => data} =
      Enum.find(envelope["arguments"]["steps"], &(&1["step"] == current))

    %{"hash" => @hash, "from" => @signer, "to" => to, "input" => data, "value" => "0x0"}
  end

  defp moved_blocks(false, _block), do: %{}

  defp moved_blocks(true, block),
    do: %{block => %{"number" => block, "hash" => "0x" <> String.duplicate("99", 32)}}

  defp staked_log,
    do: event(@splitter, SubjectAbi.selector(:staked), [word(@signer)], [uint(100)])

  defp unstaked_log,
    do: event(@splitter, SubjectAbi.selector(:unstaked), [word(@signer)], [uint(100)])

  defp claimed_log(token, amount),
    do:
      event(@splitter, SubjectAbi.selector(:claimed), [word(@signer), word(token)], [uint(amount)])

  defp routed_log(gross, referral, net),
    do:
      event(
        @receiver,
        SubjectAbi.selector(:payment_routed),
        [body(@reference), body(@reference), word(@token)],
        [uint(gross), uint(referral), uint(net)]
      )

  defp note_log(new),
    do:
      event(@receiver, SubjectAbi.selector(:receiver_note_updated), [], [
        body(@reference),
        body(new)
      ])

  defp approval_log(amount),
    do:
      event(@token, Abi.event_topic(:approval), [word(@signer), word(@splitter)], [uint(amount)])

  defp event(emitter, topic0, indexed, data),
    do: %{
      "address" => emitter,
      "topics" => [topic0 | Enum.map(indexed, &("0x" <> &1))],
      "data" => "0x" <> Enum.join(data)
    }

  defp word(address), do: BaseRpcStub.address_word(address)
  defp body("0x" <> hex), do: String.downcase(hex)
  defp uint(value), do: BaseRpcStub.hex_word(value)
end
