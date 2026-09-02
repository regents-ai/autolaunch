defmodule Autolaunch.Chain.SubjectAbiTest do
  @moduledoc """
  The exact bytes this lane may produce, the exact events it may believe, and the
  explicit absence of every superseded selector and contract name.
  """

  use ExUnit.Case, async: true

  alias Autolaunch.Chain.SubjectAbi

  @splitter "0x2222222222222222222222222222222222222222"
  @receiver "0x3333333333333333333333333333333333333333"
  @token "0x4444444444444444444444444444444444444444"
  @account "0x1111111111111111111111111111111111111111"
  @reference "0x" <> String.duplicate("7e", 32)

  describe "EXACT_C1_SELECTORS: only the seven admitted product calls are encodable" do
    test "every admitted selector is the exact one the integrated source declares" do
      assert SubjectAbi.selector(:stake) == "0xa694fc3a"
      assert SubjectAbi.selector(:unstake) == "0x2e17de78"
      assert SubjectAbi.selector(:claim) == "0x1e83409a"
      assert SubjectAbi.selector(:claim_all) == "0xd1058e59"
      assert SubjectAbi.selector(:pay) == "0x5e5571ac"
      assert SubjectAbi.selector(:sweep) == "0x8a738683"
      assert SubjectAbi.selector(:set_receiver_note) == "0xb1379b2f"
    end

    test "each selector is an independent Foundry derivation of its declared signature" do
      for id <- [:stake, :unstake, :claim, :claim_all, :pay, :sweep, :set_receiver_note] do
        assert cast(["sig", SubjectAbi.signature(id)]) == SubjectAbi.selector(id)
      end
    end

    test "calls are a selector followed by typed static words and nothing else" do
      assert SubjectAbi.encode_stake(1) ==
               "0xa694fc3a" <> String.pad_leading("1", 64, "0")

      assert SubjectAbi.encode_claim_all() == "0xd1058e59"

      assert SubjectAbi.encode_claim(@token) ==
               "0x1e83409a" <> word(@token)

      # Three words: address, uint256, bytes32. No offset, no length prefix.
      pay = SubjectAbi.encode_pay(@token, 5, @reference)

      assert pay ==
               "0x5e5571ac" <>
                 word(@token) <> String.pad_leading("5", 64, "0") <> body(@reference)

      assert byte_size(pay) == 2 + 8 + 3 * 64

      sweep = SubjectAbi.encode_sweep(@token, @reference)
      assert byte_size(sweep) == 2 + 8 + 2 * 64

      note = SubjectAbi.encode_set_receiver_note(@reference)
      assert byte_size(note) == 2 + 8 + 64
    end

    test "a malformed word is refused rather than silently padded" do
      assert_raise ArgumentError, fn -> SubjectAbi.encode_stake(-1) end
      assert_raise ArgumentError, fn -> SubjectAbi.encode_set_receiver_note("0xzz") end
      assert_raise ArgumentError, fn -> SubjectAbi.encode_claim("not-an-address") end
    end

    test "the fixed decimals of the three bound assets are product bindings" do
      assert SubjectAbi.decimals(:subject) == 18
      assert SubjectAbi.decimals(:regent) == 18
      assert SubjectAbi.decimals(:usdc) == 6
    end
  end

  describe "NO_SUPERSEDED_SURFACE: the deleted lane leaves no encoder behind" do
    test "no superseded selector or contract name is reachable from this module" do
      source = File.read!("lib/autolaunch/chain/subject_abi.ex")

      for absent <- [
            "0x7acb7757",
            "0x8381e182",
            "0x42852610",
            "0x96bc6c1a",
            "0xb12d629e",
            "0x706a7fa6",
            "0xc8c05f99",
            "0xbe25fb30",
            "PaymentLinkFactory",
            "RevenueIngressAccount",
            "RevenueShareSplitterV2",
            "claimUSDC",
            "createPaymentLink",
            "sweepUSDC"
          ] do
        refute source =~ absent
      end
    end

    test "no dynamic-string encoder survives: every admitted input is one static word" do
      source = File.read!("lib/autolaunch/chain/subject_abi.ex")

      for absent <- ["pad_dynamic", "encode_bytes", "String.pad_trailing(hex"] do
        refute source =~ absent
      end

      # Proved by shape rather than by absence alone: an admitted call's calldata
      # length is always the selector plus a whole number of 32-byte words.
      for data <- [
            SubjectAbi.encode_stake(1),
            SubjectAbi.encode_unstake(1),
            SubjectAbi.encode_claim(@token),
            SubjectAbi.encode_claim_all(),
            SubjectAbi.encode_pay(@token, 1, @reference),
            SubjectAbi.encode_sweep(@token, @reference),
            SubjectAbi.encode_set_receiver_note(@reference)
          ] do
        assert rem(byte_size(data) - 10, 64) == 0
      end
    end

    test "no C2, C3 or C4 function is encodable here" do
      for absent <- [
            "initialize",
            "depositRecognizedRevenue",
            "recognizeSurplusRevenue",
            "recoverUnsupportedToken",
            "recoverForcedETH",
            "launch(",
            "createPaymentReceiver",
            "migrate(",
            "afterSwap",
            "beforeSwap"
          ] do
        refute File.read!("lib/autolaunch/chain/subject_abi.ex") =~ absent
      end
    end
  end

  describe "EXACT_EVENT_EVIDENCE: only this action's own logs may confirm it" do
    test "every decoded topic is an independent Keccak-256 of its deployed signature" do
      for id <- [:staked, :unstaked, :claimed, :payment_routed, :receiver_note_updated] do
        assert cast(["keccak", SubjectAbi.signature(id)]) == SubjectAbi.selector(id)
      end
    end

    test "a stake is proved by exactly one matching event from its own splitter" do
      logs = [staked_log(@splitter, @account, 10)]

      assert SubjectAbi.staked?(logs, @splitter, @account, 10)
      refute SubjectAbi.staked?(logs, @splitter, @account, 11)
      refute SubjectAbi.staked?(logs, @receiver, @account, 10)
      refute SubjectAbi.staked?(logs, @splitter, @token, 10)
      refute SubjectAbi.staked?([], @splitter, @account, 10)

      # A duplicate is a contradiction, not a stronger proof.
      refute SubjectAbi.staked?(logs ++ logs, @splitter, @account, 10)
    end

    test "no claim log at all is a truthful no-op rather than a contradiction" do
      assert SubjectAbi.claimed([], @splitter, @account, [@token]) == {:ok, %{}}
    end

    test "claims are accepted only for this account, these tokens, and positive amounts" do
      usdc = "0x8888888888888888888888888888888888888888"

      assert SubjectAbi.claimed(
               [
                 claimed_log(@splitter, @account, @token, 5),
                 claimed_log(@splitter, @account, usdc, 7)
               ],
               @splitter,
               @account,
               [@token, usdc]
             ) == {:ok, %{@token => 5, usdc => 7}}

      # Wrong account, unsupported token, duplicate token and a zero amount are
      # each a contradiction.
      assert SubjectAbi.claimed([claimed_log(@splitter, usdc, @token, 5)], @splitter, @account, [
               @token
             ]) ==
               :error

      assert SubjectAbi.claimed(
               [claimed_log(@splitter, @account, usdc, 5)],
               @splitter,
               @account,
               [@token]
             ) ==
               :error

      assert SubjectAbi.claimed(
               [
                 claimed_log(@splitter, @account, @token, 5),
                 claimed_log(@splitter, @account, @token, 6)
               ],
               @splitter,
               @account,
               [@token]
             ) == :error

      assert SubjectAbi.claimed(
               [claimed_log(@splitter, @account, @token, 0)],
               @splitter,
               @account,
               [@token]
             ) ==
               :error
    end

    test "a routed payment must carry this reference, zero referral, and net equal to gross" do
      note = note_word(@receiver)

      assert SubjectAbi.payment_routed(
               [routed_log(@receiver, @reference, note, @token, 100, 0, 100)],
               @receiver,
               @reference,
               @token
             ) == {:ok, %{gross: 100, note: note}}

      for contradiction <- [
            routed_log(@receiver, other_reference(), note, @token, 100, 0, 100),
            routed_log(@receiver, @reference, note, @splitter, 100, 0, 100),
            routed_log(@receiver, @reference, note, @token, 100, 1, 99),
            routed_log(@receiver, @reference, note, @token, 100, 0, 99),
            routed_log(@receiver, @reference, note, @token, 0, 0, 0)
          ] do
        assert SubjectAbi.payment_routed([contradiction], @receiver, @reference, @token) == :error
      end

      # A log from anything but this receiver proves nothing about it.
      assert SubjectAbi.payment_routed(
               [routed_log(@splitter, @reference, note, @token, 100, 0, 100)],
               @receiver,
               @reference,
               @token
             ) == :error
    end

    test "a note update is proved by the exact new note in the event's own data" do
      note = note_word(@receiver)

      assert SubjectAbi.receiver_note_updated?(
               [note_log(@receiver, note, @reference)],
               @receiver,
               @reference
             )

      refute SubjectAbi.receiver_note_updated?(
               [note_log(@receiver, note, @reference)],
               @receiver,
               note
             )

      refute SubjectAbi.receiver_note_updated?(
               [note_log(@splitter, note, @reference)],
               @receiver,
               @reference
             )

      refute SubjectAbi.receiver_note_updated?([], @receiver, @reference)
    end
  end

  describe "NOTE_DISPLAY: a stored note is read in one fixed order" do
    test "an all-zero note reads as cleared before the address-default rule" do
      # It carries twelve leading zero bytes too, so order is what decides it.
      assert SubjectAbi.note_display("0x" <> String.duplicate("0", 64)) == :cleared
    end

    test "twelve leading zero bytes read as the receiver-address default" do
      assert SubjectAbi.note_display(note_word(@receiver)) ==
               {:address, String.downcase(@receiver)}
    end

    test "anything else reads as the editor's own text" do
      {:ok, encoded} = SubjectAbi.encode_note("Front desk")
      assert SubjectAbi.note_display(encoded) == {:text, "Front desk"}

      {:ok, empty} = SubjectAbi.encode_note("")
      assert SubjectAbi.note_display(empty) == :cleared
    end

    test "text is left-aligned, right zero-padded, and bounded at thirty-two bytes" do
      assert SubjectAbi.encode_note("a") == {:ok, "0x61" <> String.duplicate("0", 62)}
      assert {:ok, _exact} = SubjectAbi.encode_note(String.duplicate("a", 32))
      assert SubjectAbi.encode_note(String.duplicate("a", 33)) == :error

      # The bound is bytes, not characters.
      assert SubjectAbi.encode_note(String.duplicate("é", 17)) == :error
      assert {:ok, _fits} = SubjectAbi.encode_note(String.duplicate("é", 16))
      assert SubjectAbi.encode_note(<<0xFF, 0xFE>>) == :error
    end

    test "a note that is neither an address nor printable text is shown as opaque bytes" do
      opaque = "0x" <> String.duplicate("ff", 32)
      assert SubjectAbi.note_display(opaque) == {:opaque, opaque}
    end
  end

  # Log builders

  defp staked_log(emitter, account, amount),
    do: event(emitter, SubjectAbi.selector(:staked), [word(account)], [uint(amount)])

  defp claimed_log(emitter, account, token, amount),
    do:
      event(emitter, SubjectAbi.selector(:claimed), [word(account), word(token)], [uint(amount)])

  defp routed_log(emitter, reference, note, token, gross, referral, net),
    do:
      event(
        emitter,
        SubjectAbi.selector(:payment_routed),
        [body(reference), body(note), word(token)],
        [uint(gross), uint(referral), uint(net)]
      )

  defp note_log(emitter, previous, new),
    do:
      event(emitter, SubjectAbi.selector(:receiver_note_updated), [], [body(previous), body(new)])

  defp event(emitter, topic0, indexed, data),
    do: %{
      "address" => emitter,
      "topics" => [topic0 | Enum.map(indexed, &("0x" <> &1))],
      "data" => "0x" <> Enum.join(data)
    }

  defp word("0x" <> address), do: String.pad_leading(String.downcase(address), 64, "0")
  defp body("0x" <> hex), do: String.downcase(hex)

  defp uint(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp note_word("0x" <> address),
    do: "0x" <> String.duplicate("0", 24) <> String.downcase(address)

  defp other_reference, do: "0x" <> String.duplicate("11", 32)

  defp cast(args) do
    executable =
      System.find_executable("cast") || flunk("Foundry cast is required for ABI checks")

    {output, 0} = System.cmd(executable, args, stderr_to_stdout: true)
    String.trim(output)
  end
end
