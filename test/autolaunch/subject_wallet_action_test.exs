defmodule Autolaunch.SubjectWalletActionTest do
  @moduledoc """
  The seven reviewed C1 actions, the rules that gate each of them, and the
  canonical evidence each one is settled by.
  """

  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch
  alias Autolaunch.Chain.SubjectAbi
  alias Autolaunch.SubjectWalletActions
  alias Autolaunch.SubjectWalletFixture, as: Fixture

  @unit Integer.pow(10, 18)
  @usdc_unit Integer.pow(10, 6)

  setup do
    Fixture.install()
    Fixture.actor()
  end

  describe "ONE_ACTIVE_PRIVY_WALLET: only the leased account's active wallet is answered about" do
    test "a wallet the account holds is answered with its own private state", context do
      assert {:ok, state} =
               Autolaunch.subject_wallet_state(
                 context[:subject].subject_id,
                 Fixture.wallet(),
                 context[:opts]
               )

      assert state.signer == Fixture.wallet()
      assert state.balances.subject == "900"
      assert state.balances.usdc == "50"
      assert state.claimable.usdc == "12"
      assert state.staked == "400"
      assert state.total_staked == "1000"
    end

    test "a wallet the account does not hold sees no private state at all", context do
      other = "0x9999999999999999999999999999999999999999"

      assert {:error, error} =
               Autolaunch.subject_wallet_state(
                 context[:subject].subject_id,
                 other,
                 context[:opts]
               )

      assert Fixture.refusal(error) == :wrong_signer
    end

    test "a malformed address is refused before any read", context do
      assert {:error, error} =
               Autolaunch.subject_wallet_state(
                 context[:subject].subject_id,
                 "0xnope",
                 context[:opts]
               )

      assert Fixture.refusal(error) == :invalid_address
    end

    test "a signed-out caller can neither read nor prepare", context do
      anonymous = Keyword.put(context[:opts], :actor, nil)

      assert {:error, signed_out} =
               Autolaunch.subject_wallet_state(
                 context[:subject].subject_id,
                 Fixture.wallet(),
                 anonymous
               )

      assert Fixture.refusal(signed_out) == :authentication_required

      assert {:error, refused} = prepare(context, :stake, %{"amount" => "1"}, anonymous)
      assert Fixture.refusal(refused) == :authentication_required
    end
  end

  describe "EXACT_PREPARATION_RULES: every reviewed action states exactly what it will do" do
    test "a stake reviews an exact approval then the exact stake", context do
      assert {:ok, %{operation: operation}} = prepare(context, :stake, %{"amount" => "10"})

      assert operation.kind == :stake
      assert operation.step == :approval
      assert operation.state == :prepared
      assert operation.signer == Fixture.wallet()

      arguments = operation.envelope["arguments"]
      assert arguments["amount"] == "10"
      assert arguments["amount_atomic"] == Integer.to_string(10 * @unit)
      assert arguments["symbol"] == "SUBJECT"
      assert arguments["protocol_share_bps"] == 200
      # A stake is not a recognized inflow, so it divides nothing.
      assert arguments["allocation"] == nil

      assert [approval, action] = arguments["steps"]
      assert approval["step"] == "approval"
      assert approval["to"] == Fixture.token()
      assert approval["spender"] == Fixture.splitter()
      assert String.starts_with?(approval["data"], "0x095ea7b3")

      assert action["step"] == "action"
      assert action["to"] == Fixture.splitter()
      assert action["data"] == SubjectAbi.encode_stake(10 * @unit)
      assert operation.envelope["to"] == Fixture.splitter()
      assert operation.envelope["value"] == "0"
      assert operation.envelope["chain_id"] == 8453
    end

    test "an allowance that already covers the amount is spent as it stands", context do
      Fixture.install(allowance: 10 * @unit)

      assert {:ok, %{operation: operation}} = prepare(context, :stake, %{"amount" => "10"})

      assert operation.step == :action
      assert [%{"step" => "action"}] = operation.envelope["arguments"]["steps"]
    end

    test "a stake above the wallet's own balance is refused", context do
      assert {:error, error} = prepare(context, :stake, %{"amount" => "901"})
      assert Fixture.refusal(error) == :amount_above_balance
    end

    test "an unstake is capped by this wallet's own stake, never by the global total", context do
      assert {:ok, %{operation: operation}} = prepare(context, :unstake, %{"amount" => "400"})
      assert operation.step == :action
      assert [%{"data" => data}] = operation.envelope["arguments"]["steps"]
      assert data == SubjectAbi.encode_unstake(400 * @unit)

      assert {:error, error} = prepare(context, :unstake, %{"amount" => "401"})
      assert Fixture.refusal(error) == :amount_above_stake
    end

    test "claiming one asset needs that asset to be claimable right now", context do
      assert {:ok, %{operation: operation}} =
               prepare(context, :claim, %{"asset" => "usdc"})

      assert operation.envelope["arguments"]["steps"] == [
               %{
                 "step" => "action",
                 "to" => Fixture.splitter(),
                 "data" => SubjectAbi.encode_claim(Fixture.usdc())
               }
             ]

      assert {:error, error} = prepare(context, :claim, %{"asset" => "subject"})
      assert Fixture.refusal(error) == :nothing_claimable
    end

    test "claiming everything needs at least one positive claimable", context do
      assert {:ok, %{operation: operation}} = prepare(context, :claim_all, %{})
      assert [%{"data" => data}] = operation.envelope["arguments"]["steps"]
      assert data == SubjectAbi.encode_claim_all()

      Fixture.install(claimable: %{subject: 0, usdc: 0, regent: 0})
      assert {:error, error} = prepare(context, :claim_all, %{})
      assert Fixture.refusal(error) == :nothing_claimable
    end

    test "a payment carries a random reference and states where the net goes", context do
      assert {:ok, %{operation: first}} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "5"})

      assert {:ok, %{operation: second}} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "5"})

      reference = first.envelope["arguments"]["payment_reference"]
      assert byte_size(reference) == 66
      assert reference != second.envelope["arguments"]["payment_reference"]

      # The reference is part of the immutable identity, so two payments of the
      # same amount are never the same reviewed transaction.
      assert first.action_id != second.action_id

      assert [approval, action] = first.envelope["arguments"]["steps"]
      assert approval["spender"] == Fixture.receiver()
      assert action["to"] == Fixture.receiver()
      assert action["data"] == SubjectAbi.encode_pay(Fixture.usdc(), 5 * @usdc_unit, reference)
    end

    # 5 USDC is 5_000_000 atomic. The skim floors to 100_000 and the net is
    # 4_900_000. The fixture stakes 1_000 of the 100-billion SUBJECT supply, so
    # the staker allocation floors to zero and the treasury takes the whole net;
    # ten million times that stake earns exactly 490 of the same net.
    test "a payment divides into exact atomic amounts at zero and nonzero coverage", context do
      assert {:ok, %{operation: sparse}} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "5"})

      assert argument(sparse, "total_staked") == "1000000000000000000000"

      assert argument(sparse, "allocation") == %{
               "gross" => "5000000",
               "skim" => "100000",
               "net" => "4900000",
               "stakers" => "0",
               "treasury" => "4900000"
             }

      Fixture.install(total_staked: 10_000_000_000 * @unit, staked_of: 400 * @unit)

      assert {:ok, %{operation: covered}} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "5"})

      assert argument(covered, "allocation") == %{
               "gross" => "5000000",
               "skim" => "100000",
               "net" => "4900000",
               "stakers" => "490000",
               "treasury" => "4410000"
             }

      Fixture.install(total_staked: 0, staked_of: 0)

      assert {:ok, %{operation: unstaked}} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "5"})

      assert argument(unstaked, "total_staked") == "0"
      assert argument(unstaked, "allocation")["stakers"] == "0"
      assert argument(unstaked, "allocation")["treasury"] == "4900000"
    end

    # The receiver holds 7 USDC, so a sweep divides exactly what it will move.
    test "a sweep divides the receiver's own balance rather than a chosen amount", context do
      assert {:ok, %{operation: operation}} = prepare(context, :sweep, %{"asset" => "usdc"})

      assert argument(operation, "allocation") == %{
               "gross" => "7000000",
               "skim" => "140000",
               "net" => "6860000",
               "stakers" => "0",
               "treasury" => "6860000"
             }
    end

    test "a sweep reviews the receiver's own current balance", context do
      assert {:ok, %{operation: operation}} = prepare(context, :sweep, %{"asset" => "usdc"})

      arguments = operation.envelope["arguments"]
      assert arguments["amount"] == "7"
      assert [action] = arguments["steps"]

      assert action["data"] ==
               SubjectAbi.encode_sweep(Fixture.usdc(), arguments["payment_reference"])

      # Nothing is swept from an asset the receiver is not holding.
      assert {:error, error} = prepare(context, :sweep, %{"asset" => "regent"})
      assert Fixture.refusal(error) == :nothing_to_sweep
    end

    test "only the exact note editor may set a note, and only valid short text", _context do
      # A canonical receiver's note editor is the launch treasury, so only a
      # wallet that is itself that treasury may ever edit the note.
      context = Fixture.actor(treasury_address: Fixture.wallet())
      Fixture.install(treasury: Fixture.wallet())

      assert {:ok, %{operation: operation}} =
               prepare(context, :set_note, %{"note" => "Front desk"})

      {:ok, note} = SubjectAbi.encode_note("Front desk")
      assert operation.envelope["arguments"]["note"] == note
      assert [%{"data" => data}] = operation.envelope["arguments"]["steps"]
      assert data == SubjectAbi.encode_set_receiver_note(note)

      assert {:error, too_long} =
               prepare(context, :set_note, %{"note" => String.duplicate("a", 33)})

      assert Fixture.refusal(too_long) == :invalid_note
    end

    test "a wallet that is not the treasury note editor cannot set a note", context do
      assert {:error, refused} = prepare(context, :set_note, %{"note" => "Front desk"})
      assert Fixture.refusal(refused) == :not_note_editor
    end

    test "an unsupported asset is refused rather than encoded", context do
      assert {:error, error} = prepare(context, :claim, %{"asset" => "dai"})
      assert Fixture.refusal(error) == :unsupported_asset
    end

    test "an amount with more places than the asset has decimals is refused", context do
      assert {:error, error} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "1.1234567"})

      assert Fixture.refusal(error) == :invalid_amount

      assert {:ok, _six_places} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "1.123456"})
    end
  end

  describe "PROJECTED_CANONICAL_RECEIVER: payments need a projected canonical receiver" do
    test "a subject with no projected receiver refuses every payment action but still stakes" do
      context = Fixture.actor(canonical_receiver_address: nil)

      for {kind, params} <- [
            {:pay, %{"asset" => "usdc", "amount" => "1"}},
            {:sweep, %{"asset" => "usdc"}},
            {:set_note, %{"note" => "x"}}
          ] do
        assert {:error, error} = prepare(context, kind, params)
        assert Fixture.refusal(error) == :canonical_receiver_unavailable
      end

      assert {:ok, _staked} = prepare(context, :stake, %{"amount" => "1"})
    end

    test "a receiver that is not the canonical zero-referral one refuses before any review",
         context do
      for {overrides, reason} <- [
            {[referral_bps: 1], :receiver_not_canonical},
            {[beneficiary: "0x7777777777777777777777777777777777777777"],
             :receiver_not_canonical},
            {[note_editor: "0x7777777777777777777777777777777777777777"], :receiver_not_canonical}
          ] do
        Fixture.install(overrides)

        assert {:error, error} = prepare(context, :pay, %{"asset" => "usdc", "amount" => "1"})
        assert Fixture.refusal(error) == reason
      end
    end
  end

  describe "PROVEN_SPLITTER_BINDINGS: a review exists only when the launch's own splitter agrees" do
    test "the splitter's treasury must be the treasury this subject stores" do
      context = Fixture.actor(treasury_address: "0x6666666666666666666666666666666666666666")

      assert {:error, error} = prepare(context, :stake, %{"amount" => "1"})
      assert Fixture.refusal(error) == :splitter_treasury_mismatch
    end

    test "the splitter's SUBJECT, USDC and REGENT must be the pinned bindings", context do
      for {snapshot_key, reason} <- [
            {:subject, :splitter_subject_mismatch},
            {:usdc, :splitter_usdc_mismatch},
            {:regent, :splitter_regent_mismatch}
          ] do
        fixture = Fixture.fixture()

        wrong =
          put_in(
            fixture,
            [:snapshot, :splitter, snapshot_key],
            "0x7777777777777777777777777777777777777777"
          )

        Autolaunch.TestAutolaunchSubjectWalletChainClient.install(wrong)

        assert {:error, error} = prepare(context, :stake, %{"amount" => "1"})
        assert Fixture.refusal(error) == reason
      end
    end

    test "a subject off Base, or without a splitter, has no reviewable action at all" do
      off_base = Fixture.actor(splitter_address: nil)

      assert {:error, error} = prepare(off_base, :stake, %{"amount" => "1"})
      assert Fixture.refusal(error) == :subject_splitter_unavailable
    end
  end

  describe "AN_EVENT_VERIFIED_AMOUNT_REPLACES_THE_REVIEWED_ONE" do
    test "a confirmed claim reads its own reviewed token, and no event is a truthful zero",
         context do
      assert {:ok, %{operation: operation}} = prepare(context, :claim, %{"asset" => "usdc"})
      token = operation.envelope["arguments"]["token"]
      assert operation.envelope["arguments"]["amount"] == "12"

      assert verified(operation, %{"claimed" => %{token => "9500000"}}) == "9.5"
      assert verified(operation, %{"claimed" => %{}}) == "0"

      # A canonical success only ever records this claim's own token, so an
      # entry for anything else is not this claim's amount.
      assert verified(operation, %{"claimed" => %{Fixture.regent() => "5000000"}}) == "0"
    end

    test "a confirmed sweep reads the gross its routing event reported", context do
      assert {:ok, %{operation: operation}} = prepare(context, :sweep, %{"asset" => "usdc"})
      assert operation.envelope["arguments"]["amount"] == "7"

      assert verified(operation, %{"gross" => "6500000", "note" => "0x00"}) == "6.5"
      assert verified(operation, %{"gross" => "0"}) == "0"
    end

    test "nothing else, and nothing malformed, ever produces an amount", context do
      assert {:ok, %{operation: claim}} = prepare(context, :claim, %{"asset" => "usdc"})
      token = claim.envelope["arguments"]["token"]

      for result <- [
            %{},
            %{"claimed" => "not a map"},
            %{"claimed" => %{token => "twelve"}},
            %{"claimed" => %{token => 12}},
            %{"claimed" => %{token => "-1"}},
            %{"claimed" => %{token => "1.5"}},
            %{"gross" => "6500000"}
          ] do
        assert verified(claim, result) == nil
      end

      # A row that has not confirmed keeps its estimate whatever it stores.
      assert SubjectWalletActions.verified_amount(%{
               claim
               | result: %{"claimed" => %{token => "1"}}
             }) == nil

      # The other five actions never learn an amount from a result at all.
      assert {:ok, %{operation: paid}} =
               prepare(context, :pay, %{"asset" => "usdc", "amount" => "5"})

      assert verified(paid, %{"gross" => "5000000"}) == nil
    end
  end

  defp argument(operation, key), do: operation.envelope["arguments"][key]

  defp verified(operation, result),
    do: SubjectWalletActions.verified_amount(%{operation | state: :confirmed, result: result})

  defp prepare(context, kind, params, opts \\ nil) do
    Autolaunch.prepare_subject_wallet_action(
      context[:subject].subject_id,
      Fixture.wallet(),
      kind,
      params,
      opts || context[:opts]
    )
  end
end
