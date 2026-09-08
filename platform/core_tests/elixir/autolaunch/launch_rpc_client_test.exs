defmodule Autolaunch.LaunchRpcClientTest do
  @moduledoc """
  The release client: fail-closed preparation, and receipts that are evidence
  rather than success by themselves.
  """

  use ExUnit.Case, async: false

  alias Autolaunch.BaseRpcStub
  alias Autolaunch.Chain.{Abi, LaunchAbi}
  alias Autolaunch.{LaunchRpcClient}

  @client_key :autolaunch_launch_http_client
  @signer "0x1111111111111111111111111111111111111111"
  @factory "0x7777777777777777777777777777777777777777"
  @strategy "0x8888888888888888888888888888888888888888"
  @treasury "0x5555555555555555555555555555555555555555"
  @subject "0x4444444444444444444444444444444444444444"
  @auction "0x2222222222222222222222222222222222222222"
  @escrow "0x3333333333333333333333333333333333333333"
  @safe "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"
  @foreign "0xdddddddddddddddddddddddddddddddddddddddd"

  @hash "0x" <> String.duplicate("ab", 32)
  @safe_block "0x20"
  @launch_id 42
  @fee 1_000_000 * Integer.pow(10, 18)
  @raise_atomic 1_000_500_000_000_000_000_000
  @start_block 30_001_800
  @end_block 30_088_201

  describe "PRODUCTION_STAYS_FAIL_CLOSED: the release default prepares nothing" do
  end

  describe "RECEIPT_IS_EVIDENCE: only canonical state and this launch's own logs settle it" do
    test "a receipt above the safe head stays pending rather than becoming an answer" do
      install(:launch, receipt_block: "0x99", logs: launch_logs())
      assert verify(:launch) == {:ok, %{outcome: :pending}}
    end

    test "a receipt in a block that is no longer canonical stays pending" do
      install(:launch, logs: launch_logs(), moved: true)
      assert verify(:launch) == {:ok, %{outcome: :pending}}
    end

    test "a canonical revert is terminal reverted" do
      install(:launch, status: "0x0", logs: [])
      assert verify(:launch) == {:ok, %{outcome: :reverted}}
    end
  end

  describe "THE_ALLOWANCE_CORRECTION_NEEDS_ITS_OWN_EVENT" do
    test "an approval event for a different amount or spender is unverified" do
      install(:approval, logs: [approval_log(@fee - 1)])
      assert verify(:approval) == {:ok, %{outcome: :unverified}}

      install(:approval, logs: [approval_log(@fee, @foreign)])
      assert verify(:approval) == {:ok, %{outcome: :unverified}}
    end
  end

  describe "A_LAUNCH_NEEDS_ITS_EVENT_ITS_FEE_BRANCH_AND_THE_FACTORY_RECORD" do
    test "an absent, duplicated or foreign-emitter event is never a launch" do
      install(:launch, logs: [approval_log(@fee)])
      assert verify(:launch) == {:ok, %{outcome: :unverified}}

      install(:launch, logs: [launch_created_log(), launch_created_log(), fee_log()])
      assert verify(:launch) == {:ok, %{outcome: :unverified}}

      install(:launch, logs: [launch_created_log(emitter: @foreign), fee_log()])
      assert verify(:launch) == {:ok, %{outcome: :unverified}}
    end

    test "an event naming another signer, treasury or raise is unverified" do
      for override <- [
            [launcher: @foreign],
            [treasury: @foreign],
            [required_raise: @raise_atomic + 1]
          ] do
        install(:launch, logs: [launch_created_log(override), fee_log()])
        assert verify(:launch) == {:ok, %{outcome: :unverified}}, "#{inspect(override)} confirmed"
      end
    end
  end

  # Envelopes, logs and the scripted factory

  defp verify(step, options \\ []),
    do: LaunchRpcClient.verify(envelope(options), step, @hash)

  defp envelope(options) do
    fee = Keyword.get(options, :fee, @fee)

    %{
      "expected_signer" => @signer,
      "to" => @factory,
      "arguments" => %{
        "factory" => @factory,
        "strategy" => @strategy,
        "regent" => Abi.regent_address(),
        "treasury" => @treasury,
        "required_regent_raised_atomic" => Integer.to_string(@raise_atomic),
        "expected_launch_fee_atomic" => Integer.to_string(fee),
        "steps" => steps(fee)
      }
    }
  end

  defp steps(fee) do
    [
      %{
        "step" => "approval",
        "to" => Abi.regent_address(),
        "spender" => @factory,
        "amount" => Integer.to_string(fee),
        "data" => Abi.encode_erc20("approve", [@factory, fee])
      },
      %{"step" => "launch", "to" => @factory, "data" => launch_data(fee)}
    ]
  end

  defp launch_data(fee) do
    LaunchAbi.encode_launch(%{
      name: "Open Research",
      symbol: "OPEN",
      description: "A launch profile awaiting review.",
      website: "https://example.test/open",
      image: "https://example.test/open.png",
      treasury: @treasury,
      required_regent_raised: @raise_atomic,
      expected_launch_fee: fee
    })
  end

  # The stub answers about exactly one transaction: the step's own target and
  # calldata, mined into a canonical block at or below the safe head, plus the
  # factory record and subject mapping the receipt block should already hold.
  defp install(step, options) do
    logs = Keyword.get(options, :logs, [])
    status = Keyword.get(options, :status, "0x1")
    block = Keyword.get(options, :receipt_block, @safe_block)
    fee = Keyword.get(options, :fee, @fee)
    calls = Keyword.get(options, :calls, factory_reads(options))

    BaseRpcStub.install(@client_key, calls)

    BaseRpcStub.put(%{
      receipts: %{@hash => BaseRpcStub.receipt(@hash, block, logs, status)},
      transactions: %{@hash => transaction(step, fee)},
      blocks: moved_blocks(Keyword.get(options, :moved, false), block)
    })
  end

  defp transaction(step, fee) do
    current = Atom.to_string(step)
    %{"to" => to, "data" => data} = Enum.find(steps(fee), &(&1["step"] == current))

    %{"hash" => @hash, "from" => @signer, "to" => to, "input" => data, "value" => "0x0"}
  end

  # One scripted factory: its recorded launch, its subject mapping, and the REGENT
  # allowance a correction left behind.
  defp factory_reads(options) do
    record = Keyword.get(options, :record, %{})
    subject_launch_id = Keyword.get(options, :subject_launch_id, @launch_id)
    launches = LaunchAbi.selector(:launches)
    mapping = LaunchAbi.selector(:launch_id_of_subject)

    fn data, _state ->
      cond do
        String.starts_with?(data, launches) -> record_words(record)
        String.starts_with?(data, mapping) -> BaseRpcStub.uint(subject_launch_id)
        true -> BaseRpcStub.uint(@fee)
      end
    end
  end

  defp record_words(:absent), do: "0x" <> String.duplicate(BaseRpcStub.hex_word(0), 5)

  defp record_words(overrides) do
    record =
      Map.merge(
        %{
          launcher: @signer,
          subject: @subject,
          auction: @auction,
          escrow: @escrow,
          treasury: @treasury
        },
        overrides
      )

    "0x" <>
      Enum.map_join(
        [:launcher, :subject, :auction, :escrow, :treasury],
        &BaseRpcStub.address_word(Map.fetch!(record, &1))
      )
  end

  defp moved_blocks(false, _block), do: %{}

  defp moved_blocks(true, block),
    do: %{block => %{"number" => block, "hash" => "0x" <> String.duplicate("99", 32)}}

  defp launch_logs, do: [launch_created_log(), fee_log()]

  defp launch_created_log(overrides \\ []) do
    emitter = Keyword.get(overrides, :emitter, @factory)

    event(
      emitter,
      LaunchAbi.selector(:launch_created),
      [
        uint(@launch_id),
        word(Keyword.get(overrides, :launcher, @signer)),
        word(@subject)
      ],
      [
        word(@auction),
        word(@escrow),
        word(Keyword.get(overrides, :treasury, @treasury)),
        uint(Keyword.get(overrides, :required_raise, @raise_atomic)),
        uint(@start_block),
        uint(@end_block)
      ]
    )
  end

  defp fee_log(overrides \\ []) do
    event(
      @factory,
      LaunchAbi.selector(:launch_fee_collected),
      [uint(@launch_id), word(@signer)],
      [word(@safe), uint(Keyword.get(overrides, :amount, @fee))]
    )
  end

  defp approval_log(amount, spender \\ @factory) do
    event(
      Abi.regent_address(),
      Abi.event_topic(:approval),
      [word(@signer), word(spender)],
      [uint(amount)]
    )
  end

  # Every log carries the block it was mined in, which is the block the factory
  # reads are then pinned to.
  defp event(emitter, topic0, indexed, data),
    do: %{
      "address" => emitter,
      "blockHash" => BaseRpcStub.receipt_block_hash(),
      "topics" => [topic0 | Enum.map(indexed, &("0x" <> &1))],
      "data" => "0x" <> Enum.join(data)
    }

  defp word(address), do: BaseRpcStub.address_word(address)
  defp uint(value), do: BaseRpcStub.hex_word(value)
end
