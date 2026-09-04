defmodule Autolaunch.LaunchActionTest do
  @moduledoc """
  What one saved draft is allowed to become: the exact reviewed sequence, the
  exact allowance rule including zero, and every reason a launch is refused
  before a durable, sendable review can exist at all.
  """

  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch
  alias Autolaunch.Chain.{Abi, Envelope, LaunchAbi}
  alias Autolaunch.LaunchFixture, as: Fixture
  alias Autolaunch.TestAutolaunchLaunchChainClient, as: ChainClient
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: TreasuryClient

  @unit Integer.pow(10, 18)
  @fee 1_000_000 * @unit
  @other_wallet "0x9999999999999999999999999999999999999999"
  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  describe "THE_EXACT_ALLOWANCE_RULE: an allowance is corrected to the fee, never approached" do
    test "a standing allowance already equal to the fee yields the launch alone", context do
      Fixture.install(allowance: @fee)

      assert {:ok, operation} = review(context)
      assert operation.step == :launch
      assert [%{"step" => "launch"}] = steps(operation)
    end

    test "a different positive allowance is corrected to exactly the fee first", context do
      Fixture.install(allowance: 7 * @unit)

      assert {:ok, operation} = review(context)
      assert operation.step == :approval
      assert [approval, %{"step" => "launch"}] = steps(operation)

      assert approval["to"] == Abi.regent_address()
      assert approval["spender"] == Fixture.factory()
      assert approval["amount"] == Integer.to_string(@fee)
      assert approval["data"] == Abi.encode_erc20("approve", [Fixture.factory(), @fee])
    end

    test "a zero fee with a standing allowance prepares an exact approve to zero", context do
      Fixture.install(fee: 0, allowance: 5 * @unit)

      assert {:ok, operation} = review(context)
      assert [approval, %{"step" => "launch"}] = steps(operation)

      assert approval["amount"] == "0"
      assert approval["data"] == Abi.encode_erc20("approve", [Fixture.factory(), 0])
    end

    test "a zero fee with a zero allowance is already exact and yields one launch", context do
      Fixture.install(fee: 0, allowance: 0)

      assert {:ok, operation} = review(context)
      assert operation.step == :launch
      assert [%{"step" => "launch"}] = steps(operation)
    end

    test "a higher allowance is still corrected downwards rather than spent as it stands",
         context do
      Fixture.install(allowance: @fee * 10)

      assert {:ok, operation} = review(context)
      assert [approval, _launch] = steps(operation)
      assert approval["amount"] == Integer.to_string(@fee)
    end
  end

  describe "ONE_IMMUTABLE_REVIEW: the bytes are encoded once and stored once" do
    test "the stored launch calldata is the exact tuple this draft names", context do
      Fixture.install()

      assert {:ok, operation} = review(context)
      launch = Enum.find(steps(operation), &(&1["step"] == "launch"))

      assert launch["to"] == Fixture.factory()

      assert launch["data"] ==
               LaunchAbi.encode_launch(%{
                 name: "Open Research",
                 symbol: "OPEN",
                 description: "A launch profile awaiting review.",
                 website: "https://example.test/open",
                 image: context[:draft].image,
                 treasury: Fixture.treasury(),
                 required_regent_raised: 1_000_500_000_000_000_000_000,
                 expected_launch_fee: @fee
               })

      # The envelope itself carries the same bytes, so dispatch has nothing left
      # to decide and no second encoder exists anywhere.
      assert operation.envelope["data"] == launch["data"]
      assert operation.envelope["to"] == Fixture.factory()
      assert operation.envelope["value"] == "0"
      assert operation.envelope["chain_id"] == 8453
    end

    test "an account-owned draft carries its stored image URL", context do
      Fixture.install(allowance: @fee)

      assert {:ok, operation} = review(context)
      assert argument(operation, "image") == context[:draft].image
      assert String.contains?(context[:draft].image, "/images/")
    end

    test "a snapshot naming another REGENT address is refused", context do
      Fixture.install(allowance: @fee, regent: @other_wallet)
      assert refused(context) == :regent_address_mismatch
    end

    test "the review displays the human decimal and encodes only the atomic integer", context do
      Fixture.install()

      assert {:ok, operation} = review(context)

      assert argument(operation, "required_regent_raised") == "1000.5"
      assert argument(operation, "required_regent_raised_atomic") == "1000500000000000000000"
      assert argument(operation, "expected_launch_fee") == "1000000"
      assert argument(operation, "expected_launch_fee_atomic") == Integer.to_string(@fee)
    end

    test "the review pins the safe block, both bound identities, and every frozen term",
         context do
      Fixture.install()

      assert {:ok, operation} = review(context)

      assert argument(operation, "block_number") == 30_000_000
      assert argument(operation, "block_hash") == "0x" <> String.duplicate("ab", 32)
      assert argument(operation, "factory") == Fixture.factory()
      assert argument(operation, "strategy") == Fixture.strategy()
      assert argument(operation, "regent") == Abi.regent_address()

      assert argument(operation, "terms") ==
               Map.new(Fixture.terms(), fn {id, value} ->
                 {Atom.to_string(id), Integer.to_string(value)}
               end)
    end

    test "the confirmation token still validates the stored envelope after its window ends",
         context do
      Fixture.install()
      assert {:ok, operation} = review(context)

      envelope = atomize(operation.envelope)
      assert Envelope.valid?(envelope, resource: "autolaunch_launch")

      # A durable submitted hash stays verifiable once the signing window closes,
      # which is what `autolaunch_launch` is on the confirm-after-expiry list for.
      elapsed = fn -> DateTime.add(DateTime.utc_now(), 3_600, :second) end
      Application.put_env(:autolaunch, :wallet_action_clock, elapsed)
      on_exit(fn -> Application.delete_env(:autolaunch, :wallet_action_clock) end)

      refute Envelope.valid?(envelope)
      assert Envelope.valid_for_confirmation?(envelope, resource: "autolaunch_launch")
    end

    test "the risk copy names what actually moves, including when the fee is zero", context do
      Fixture.install()
      assert {:ok, positive} = review(context)
      assert positive.envelope["risk_copy"] =~ "pays 1000000 REGENT"

      assert {:ok, _cancelled} =
               Autolaunch.cancel_launch_review(positive.action_id, opts(context))

      ChainClient.put(Fixture.fixture(fee: 0))
      assert {:ok, free} = review(context)
      assert free.envelope["risk_copy"] =~ "launch fee is zero right now, so no REGENT moves"
    end
  end

  describe "NO_SENDABLE_REVIEW_WITHOUT_EVERY_FACT: refusals leave nothing to dispatch" do
    test "a stale tab cannot prepare after another tab changes the persisted EOA acknowledgement",
         context do
      Fixture.install()

      valid =
        Autolaunch.autosave_launch_treasury!(
          context[:draft],
          %{
            "treasury" => Fixture.treasury(),
            "treasury_path" => "eoa",
            "eoa_acknowledgement" => @eoa_acknowledgement
          },
          actor: context[:actor]
        )

      Autolaunch.autosave_launch_treasury!(
        valid,
        %{
          "treasury" => Fixture.treasury(),
          "treasury_path" => "eoa",
          "eoa_acknowledgement" => "stale second-tab value"
        },
        actor: context[:actor]
      )

      assert Fixture.refusal(Autolaunch.prepare_launch(valid.id, Fixture.wallet(), opts(context))) ==
               :launch_treasury_invalid

      assert {:ok, %{operation: nil}} = Autolaunch.open_launch_operation(opts(context))
    end

    test "a paused factory refuses before an operation exists", context do
      Fixture.install(paused: true)
      assert refused(context) == :launches_paused
      assert {:ok, %{operation: nil}} = Autolaunch.open_launch_operation(opts(context))
    end

    test "a wallet that cannot cover the fee refuses", context do
      Fixture.install(balance: @fee - 1)
      assert refused(context) == :insufficient_regent
    end

    # The strategy itself refuses exactly these six as a launch treasury, so a
    # draft naming one is refused here rather than reverting in a wallet. Three
    # are read at the reviewed block and three are frozen Base bindings.
    test "each of the exact six contract-refused treasuries is refused before any review",
         context do
      Fixture.install()

      for refused <- [
            Fixture.factory(),
            Fixture.strategy(),
            Fixture.hook(),
            "0x498581fF718922c3f8e6A244956aF099B2652b2b",
            "0x7C5f5A4bBd8fD63184577525326123B519429bDc",
            "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5"
          ] do
        draft =
          Autolaunch.autosave_launch_treasury!(
            context[:draft],
            %{"treasury" => refused},
            actor: context[:actor]
          )

        assert Fixture.refusal(
                 Autolaunch.prepare_launch(draft.id, Fixture.wallet(), opts(context))
               ) == :launch_treasury_refused
      end

      # A refused address written in another casing is still that address.
      lowered =
        Autolaunch.autosave_launch_treasury!(
          context[:draft],
          %{"treasury" => String.downcase("0x498581fF718922c3f8e6A244956aF099B2652b2b")},
          actor: context[:actor]
        )

      assert Fixture.refusal(
               Autolaunch.prepare_launch(lowered.id, Fixture.wallet(), opts(context))
             ) == :launch_treasury_refused
    end

    # The strategy maximum is 658201822928399999.999999581824872526 REGENT, so
    # the boundary is proved from both sides rather than approximated.
    test "the exact strategy maximum is reviewable and one atomic unit more is not", context do
      Fixture.install()

      at_maximum =
        Autolaunch.autosave_launch_token_details!(
          context[:draft],
          %{"required_regent_raised" => "658201822928399999.999999581824872526"},
          actor: context[:actor]
        )

      assert {:ok, %{operation: operation}} =
               Autolaunch.prepare_launch(at_maximum.id, Fixture.wallet(), opts(context))

      assert argument(operation, "required_regent_raised_atomic") ==
               "658201822928399999999999581824872526"

      assert {:ok, _cancelled} =
               Autolaunch.cancel_launch_review(operation.action_id, opts(context))

      excessive =
        Autolaunch.autosave_launch_token_details!(
          at_maximum,
          %{"required_regent_raised" => "658201822928399999.999999581824872527"},
          actor: context[:actor]
        )

      assert Fixture.refusal(
               Autolaunch.prepare_launch(excessive.id, Fixture.wallet(), opts(context))
             ) == :required_raise_unreachable
    end

    test "a strategy that does not point back at this factory refuses", context do
      Fixture.install(strategy_factory: @other_wallet)
      assert refused(context) == :strategy_not_bound
    end

    test "a draft written before the nonempty metadata rule is refused at review", _context do
      Fixture.install()
      {historical, historical_opts} = historical_draft!()

      assert Fixture.refusal(
               Autolaunch.prepare_launch(historical.id, Fixture.wallet(), historical_opts)
             ) == :launch_metadata_incomplete
    end

    test "an account-owned row carrying only a raw external image URL is refused", _context do
      Fixture.install()

      unique = System.unique_integer([:positive])

      account =
        Autolaunch.Accounts.register_verified!(
          "did:privy:raw-account-image-#{unique}",
          Fixture.wallet(),
          [Fixture.wallet()],
          actor: system()
        )

      {:ok, :bind, claim} =
        Autolaunch.Accounts.SessionAuthority.sign_in(
          Autolaunch.Accounts.SessionAuthority.bootstrap(),
          account.id
        )

      actor = %Autolaunch.Actors.Human{human_account_id: account.id}

      raw_opts =
        [
          actor: actor,
          context: %{session_lease: %{lineage: claim.lineage, account_id: account.id}}
        ]

      raw =
        Ash.Seed.seed!(Autolaunch.LaunchDraft, %{
          name: "Raw URL",
          symbol: "RAW",
          description: "No owned image row exists.",
          website: "https://example.test/raw",
          image: "https://example.test/raw.png",
          treasury: Fixture.treasury(),
          required_regent_raised: "1000.5",
          human_account_id: account.id
        })

      assert Fixture.refusal(Autolaunch.prepare_launch(raw.id, Fixture.wallet(), raw_opts)) ==
               :launch_metadata_incomplete
    end

    # A draft may hold any 40-hex address in any casing, but mixed case asserts an
    # EIP-55 checksum. One that does not hold is refused here rather than sent to
    # a wallet, and the customer is told which field to re-enter.
    test "an address whose own checksum does not hold is refused before any wallet", context do
      Fixture.install()

      draft =
        Autolaunch.autosave_launch_treasury!(
          context[:draft],
          %{"treasury" => "0xAbCdeF0000000000000000000000000000000001"},
          actor: context[:actor]
        )

      assert Fixture.refusal(Autolaunch.prepare_launch(draft.id, Fixture.wallet(), opts(context))) ==
               :launch_treasury_invalid
    end

    test "a valid all-uppercase treasury matches its canonical stored report", context do
      Fixture.install()
      uppercase = "0xABCDEF0000000000000000000000000000000001"
      TreasuryClient.seed_verified!(String.downcase(uppercase))

      draft =
        Autolaunch.autosave_launch_treasury!(
          context[:draft],
          %{"treasury" => uppercase},
          actor: context[:actor]
        )

      assert {:ok, %{operation: operation}} =
               Autolaunch.prepare_launch(draft.id, Fixture.wallet(), opts(context))

      assert argument(operation, "treasury") == String.downcase(uppercase)
    end

    test "a restored Safe remains permanently downgraded before launch admission", context do
      Fixture.install()

      TreasuryClient.install(
        block_number: 30_000_001,
        block_hash: "0x" <> String.duplicate("ef", 32),
        threshold: 1
      )

      assert {:ok, _changed} =
               Autolaunch.observe_treasury_security(Fixture.treasury(), %{}, actor: system())

      restored =
        TreasuryClient.seed_verified!(Fixture.treasury(),
          block_number: 30_000_002,
          block_hash: "0x" <> String.duplicate("ee", 32)
        )

      assert restored.downgrade_state == :downgraded
      assert refused(context) == :treasury_not_verified
      assert {:ok, %{operation: nil}} = Autolaunch.open_launch_operation(opts(context))
    end

    test "an incomplete snapshot is refused rather than partly believed", context do
      Fixture.install()
      ChainClient.put(%{snapshot: Map.delete(ChainClient.state().snapshot, :allowance)})

      assert refused(context) == :launch_snapshot_incomplete
    end

    test "a snapshot that cannot be read at all refuses without a verdict", context do
      Fixture.install(unavailable: :chain_unavailable)
      assert refused(context) == :chain_unavailable
    end

    # The production client is the default, and it prepares nothing while no C5
    # address or runtime admission exists.
    test "production refuses every review by default, with no client installed", context do
      assert Application.get_env(:autolaunch, :autolaunch_launch_chain_client) == nil
      assert refused(context) == :launch_preparation_unavailable
    end
  end

  describe "THE_ACTIVE_WALLET_IS_THE_ONLY_SIGNER: nothing falls back to a stored one" do
    test "TREASURY_DRIFT_ENDS_THE_REVIEW_BEFORE_THE_WALLET_OPENS", context do
      Fixture.install()
      assert {:ok, operation} = review(context)

      TreasuryClient.install(
        block_number: 30_000_001,
        block_hash: "0x" <> String.duplicate("ef", 32),
        threshold: 1
      )

      assert {:ok, %{operation: ended}} =
               Autolaunch.claim_launch_dispatch(
                 operation.action_id,
                 Fixture.wallet(),
                 opts(context)
               )

      assert ended.state == :invalidated
      assert ended.reason == "the treasury security state changed"
    end

    test "a wallet this account does not hold is refused before any private fact", context do
      Fixture.install()

      assert Fixture.refusal(
               Autolaunch.prepare_launch(context[:draft].id, @other_wallet, opts(context))
             ) == :wrong_signer

      assert Fixture.refusal(Autolaunch.launch_wallet_state(@other_wallet, opts(context))) ==
               :wrong_signer
    end

    test "the held wallet is answered about and becomes the review's only signer", context do
      Fixture.install()

      assert {:ok, %{signer: signer}} =
               Autolaunch.launch_wallet_state(Fixture.wallet(), opts(context))

      assert signer == Fixture.wallet()
      assert {:ok, operation} = review(context)
      assert operation.signer == Fixture.wallet()
      assert operation.envelope["expected_signer"] == Fixture.wallet()
    end

    test "a draft another account owns is never named", context do
      Fixture.install()
      other = Fixture.actor()

      assert Fixture.refusal(
               Autolaunch.prepare_launch(other[:draft].id, Fixture.wallet(), opts(context))
             ) == :launch_draft_not_found
    end

    test "an anonymous caller and one carrying no lease are both refused", context do
      Fixture.install()

      assert Fixture.refusal(
               Autolaunch.prepare_launch(context[:draft].id, Fixture.wallet(), actor: nil)
             ) == :authentication_required

      assert Fixture.refusal(
               Autolaunch.prepare_launch(
                 context[:draft].id,
                 Fixture.wallet(),
                 Keyword.delete(opts(context), :context)
               )
             ) == :session_lease_required
    end
  end

  setup do
    context = Fixture.actor()
    TreasuryClient.seed_verified!(Fixture.treasury())

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    context
  end

  # Helpers

  defp review(context) do
    with {:ok, %{operation: operation}} <-
           Autolaunch.prepare_launch(context[:draft].id, Fixture.wallet(), opts(context)),
         do: {:ok, operation}
  end

  defp refused(context), do: Fixture.refusal(review(context))

  defp opts(context), do: context[:opts]

  defp steps(operation), do: operation.envelope["arguments"]["steps"]

  defp argument(operation, key), do: operation.envelope["arguments"][key]

  defp system, do: %Autolaunch.Actors.System{}

  # A row written before the nonempty metadata rule: it holds a name and a symbol
  # and nothing else, exactly as `LaunchDraft` still allows one to be read.
  defp historical_draft! do
    unique = System.unique_integer([:positive])

    account =
      Autolaunch.Accounts.register_verified!(
        "did:privy:historical-incomplete-#{unique}",
        Fixture.wallet(),
        [Fixture.wallet()],
        actor: system()
      )

    {:ok, :bind, claim} =
      Autolaunch.Accounts.SessionAuthority.sign_in(
        Autolaunch.Accounts.SessionAuthority.bootstrap(),
        account.id
      )

    actor = %Autolaunch.Actors.Human{human_account_id: account.id}

    draft =
      Ash.Seed.seed!(Autolaunch.LaunchDraft, %{
        name: "Legacy Research",
        symbol: "LEGACY",
        human_account_id: account.id
      })

    opts = [
      actor: actor,
      context: %{session_lease: %{lineage: claim.lineage, account_id: account.id}}
    ]

    {draft, opts}
  end

  defp atomize(envelope) do
    envelope
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Map.update!(:metadata, &Map.new(&1, fn {k, v} -> {String.to_existing_atom(k), v} end))
  end
end
