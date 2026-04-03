defmodule Autolaunch.RevenueTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.Revenue.Abi
  alias Autolaunch.Revenue.SubjectActionRegistration
  alias Autolaunch.Revenue

  @subject_id "0x" <> String.duplicate("1a", 32)
  @splitter "0x9999999999999999999999999999999999999999"
  @token "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @ingress "0x7777777777777777777777777777777777777777"
  @wallet "0x1111111111111111111111111111111111111111"

  setup do
    previous_adapter = Application.get_env(:autolaunch, :cca_rpc_adapter)
    previous_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(:autolaunch, :cca_rpc_adapter, __MODULE__.FakeRpc)

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.put(
        previous_launch,
        :revenue_ingress_factory_address,
        "0x2222222222222222222222222222222222222222"
      )
    )

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_adapter)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end

      Application.put_env(:autolaunch, :launch, previous_launch)
    end)

    human =
      %HumanUser{}
      |> HumanUser.changeset(%{
        privy_user_id: "did:privy:revenue",
        wallet_address: @wallet,
        wallet_addresses: [@wallet],
        display_name: "Operator"
      })
      |> Repo.insert!()

    now = DateTime.utc_now()
    nonce = "nonce-#{System.unique_integer([:positive])}"

    {:ok, job} =
      %Job{}
      |> Job.create_changeset(%{
        job_id: "job_subject",
        owner_address: @wallet,
        agent_id: "11155111:42",
        token_name: "Atlas Coin",
        token_symbol: "ATLAS",
        recovery_safe_address: @wallet,
        auction_proceeds_recipient: @wallet,
        ethereum_revenue_treasury: @wallet,
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "ready",
        step: "ready",
        total_supply: "1000",
        message: "signed",
        siwa_nonce: nonce,
        siwa_signature: "sig",
        issued_at: now
      })
      |> Repo.insert()

    job
    |> Job.update_changeset(%{
      token_address: @token,
      strategy_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      subject_registry_address: "0x3333333333333333333333333333333333333333",
      revenue_share_splitter_address: @splitter,
      default_ingress_address: @ingress,
      subject_id: @subject_id
    })
    |> Repo.update!()

    %{human: human}
  end

  test "get_subject returns wallet and ingress state", %{human: human} do
    assert {:ok, subject} = Revenue.get_subject(@subject_id, human)

    assert subject.subject_id == @subject_id
    assert subject.splitter_address == @splitter
    assert subject.wallet_stake_balance == "12"
    assert subject.claimable_usdc == "5"
    assert subject.claimable_stake_token == "4"
    assert subject.materialized_outstanding == "3"
    assert subject.available_reward_inventory == "8"
    assert subject.total_claimed_so_far == "6"
    assert subject.default_ingress_address == @ingress
    assert Enum.any?(subject.ingress_accounts, &(&1.address == @ingress and &1.is_default))
  end

  test "subject_obligation_metrics computes exact accrued totals from a provided staker list" do
    assert {:ok, metrics} =
             Revenue.subject_obligation_metrics(@subject_id, [
               "0x1111111111111111111111111111111111111111",
               "0x2222222222222222222222222222222222222222"
             ])

    assert metrics.subject_id == @subject_id
    assert metrics.staker_count == 2
    assert metrics.exact_total_accrued_obligations == "7"
    assert metrics.materialized_outstanding == "3"
    assert metrics.available_reward_inventory == "8"
    assert metrics.total_claimed_so_far == "6"
    assert metrics.accrued_but_unsynced == "4"
    assert metrics.funding_gap == "0"
  end

  test "get_subject accepts uppercase subject ids", %{human: human} do
    upper_subject_id = "0x" <> String.upcase(String.slice(@subject_id, 2..-1//1))

    assert {:ok, subject} = Revenue.get_subject(upper_subject_id, human)
    assert subject.subject_id == @subject_id
  end

  test "stake returns canonical tx request", %{human: human} do
    assert {:ok, %{tx_request: tx_request}} =
             Revenue.stake(@subject_id, %{"amount" => "1.5"}, human)

    assert tx_request.chain_id == 11_155_111
    assert tx_request.to == @splitter
    assert String.starts_with?(tx_request.data, "0x7acb7757")
  end

  test "stake with tx hash persists pending and reuses the registration", %{human: human} do
    tx_hash = "0x" <> String.duplicate("a", 64)
    amount_wei = 1_500_000_000_000_000_000

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Abi.encode_stake(amount_wei, @wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, nil)

    assert {:error, :transaction_pending} =
             Revenue.stake(@subject_id, %{"amount" => "1.5", "tx_hash" => tx_hash}, human)

    assert %SubjectActionRegistration{
             status: "pending",
             subject_id: @subject_id,
             action: "stake"
           } = Repo.get_by(SubjectActionRegistration, tx_hash: tx_hash)

    assert {:error, :transaction_pending} =
             Revenue.stake(@subject_id, %{"amount" => "1.5", "tx_hash" => tx_hash}, human)

    assert %SubjectActionRegistration{status: "pending"} =
             Repo.get_by(SubjectActionRegistration, tx_hash: tx_hash)
  end

  test "stake with tx hash requires amount", %{human: human} do
    assert {:error, :amount_required} =
             Revenue.stake(@subject_id, %{"tx_hash" => "0x" <> String.duplicate("b", 64)}, human)
  end

  test "stake selector mismatch returns transaction_data_mismatch", %{human: human} do
    tx_hash = "0x" <> String.duplicate("c", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Abi.encode_claim_usdc(@wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, nil)

    assert {:error, :transaction_data_mismatch} =
             Revenue.stake(@subject_id, %{"amount" => "1.5", "tx_hash" => tx_hash}, human)
  end

  test "unstake decoded amount mismatch returns transaction_data_mismatch", %{human: human} do
    tx_hash = "0x" <> String.duplicate("d", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Abi.encode_unstake(500_000_000_000_000_000, @wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, nil)

    assert {:error, :transaction_data_mismatch} =
             Revenue.unstake(@subject_id, %{"amount" => "1.0", "tx_hash" => tx_hash}, human)
  end

  test "same tx hash on a different action is rejected", %{human: human} do
    tx_hash = "0x" <> String.duplicate("e", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Abi.encode_stake(1_500_000_000_000_000_000, @wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, nil)

    assert {:error, :transaction_pending} =
             Revenue.stake(@subject_id, %{"amount" => "1.5", "tx_hash" => tx_hash}, human)

    assert {:error, :transaction_hash_reused} =
             Revenue.claim_usdc(@subject_id, %{"tx_hash" => tx_hash}, human)
  end

  test "claim_usdc refreshes subject after tx receipt", %{human: human} do
    tx_hash = "0x" <> String.duplicate("a", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Abi.encode_claim_usdc(@wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, %{
      transaction_hash: tx_hash,
      status: 1,
      from: @wallet,
      to: @splitter,
      logs: []
    })

    assert {:ok, %{subject: subject}} =
             Revenue.claim_usdc(@subject_id, %{"tx_hash" => tx_hash}, human)

    assert subject.subject_id == @subject_id
  end

  test "sweep_ingress refreshes the subject after a confirmed ingress sweep", %{human: human} do
    tx_hash = "0x" <> String.duplicate("b", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @ingress,
      input: Abi.encode_sweep_usdc(@subject_id),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, %{
      transaction_hash: tx_hash,
      status: 1,
      from: @wallet,
      to: @ingress,
      logs: []
    })

    assert {:ok, %{subject: subject}} =
             Revenue.sweep_ingress(@subject_id, @ingress, %{"tx_hash" => tx_hash}, human)

    assert subject.subject_id == @subject_id
    assert subject.default_ingress_address == @ingress
  end

  test "malformed tx hashes fail closed", %{human: human} do
    assert {:error, :invalid_transaction_hash} =
             Revenue.stake(@subject_id, %{"amount" => "1.0", "tx_hash" => "bad-hash"}, human)
  end

  defmodule FakeRpc do
    @splitter "0x9999999999999999999999999999999999999999"
    @token "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    @ingress_factory "0x2222222222222222222222222222222222222222"
    @subject_registry "0x3333333333333333333333333333333333333333"
    @ingress "0x7777777777777777777777777777777777777777"
    @usdc "0x5555555555555555555555555555555555555555"

    def block_number(_chain_id), do: {:ok, 1}

    def eth_call(11_155_111, @splitter, data) do
      selector = String.slice(data, 0, 10)

      case selector do
        "0x817b1cd2" -> {:ok, encode_uint(250 * Integer.pow(10, 18))}
        "0x966ed108" -> {:ok, encode_uint(25 * Integer.pow(10, 6))}
        "0x76459dd5" -> {:ok, encode_uint(10 * Integer.pow(10, 6))}
        "0x5f78d5f4" -> {:ok, encode_uint(1 * Integer.pow(10, 6))}
        "0x60217267" -> {:ok, encode_uint(12 * Integer.pow(10, 18))}
        "0xb026ee79" -> {:ok, encode_uint(5 * Integer.pow(10, 6))}
        "0x05e1fd68" -> {:ok, encode_uint(preview_claimable_stake_token(data))}
        "0x05f15537" -> {:ok, encode_uint(3 * Integer.pow(10, 18))}
        "0xcfb3d0aa" -> {:ok, encode_uint(8 * Integer.pow(10, 18))}
        "0x66ffb8de" -> {:ok, encode_uint(6 * Integer.pow(10, 18))}
        "0x3e413bee" -> {:ok, encode_address(@usdc)}
        _ -> {:error, :unsupported_call}
      end
    end

    def eth_call(11_155_111, @token, "0x70a08231" <> _rest),
      do: {:ok, encode_uint(90 * Integer.pow(10, 18))}

    def eth_call(11_155_111, @usdc, "0x70a08231" <> _rest),
      do: {:ok, encode_uint(7 * Integer.pow(10, 6))}

    def eth_call(11_155_111, @ingress_factory, data) do
      selector = String.slice(data, 0, 10)

      case selector do
        "0xca23dd76" -> {:ok, encode_uint(1)}
        "0xb87d9995" -> {:ok, encode_address(@ingress)}
        "0xb396721d" -> {:ok, encode_address(@ingress)}
        _ -> {:error, :unsupported_call}
      end
    end

    def eth_call(11_155_111, @subject_registry, "0x41c2ab07" <> _rest),
      do: {:ok, encode_bool(true)}

    def eth_call(_chain_id, _to, _data), do: {:error, :unsupported_call}

    def tx_by_hash(_chain_id, tx_hash) do
      case Process.get(:fake_rpc_transaction) do
        %{transaction_hash: ^tx_hash} = tx -> {:ok, tx}
        _ -> {:ok, nil}
      end
    end

    def tx_receipt(_chain_id, _tx_hash), do: {:ok, Process.get(:fake_rpc_receipt)}
    def get_logs(_chain_id, _filter), do: {:ok, []}

    defp encode_uint(value) do
      value
      |> Integer.to_string(16)
      |> String.pad_leading(64, "0")
      |> then(&("0x" <> &1))
    end

    defp encode_address(address) do
      "0x" <> String.pad_leading(String.slice(address, 2..-1//1), 64, "0")
    end

    defp encode_bool(true), do: "0x" <> String.pad_leading("1", 64, "0")

    defp preview_claimable_stake_token(<<"0x05e1fd68", encoded::binary>>) do
      case String.slice(encoded, -40, 40) |> String.downcase() do
        "1111111111111111111111111111111111111111" -> 4 * Integer.pow(10, 18)
        "2222222222222222222222222222222222222222" -> 3 * Integer.pow(10, 18)
        _ -> 0
      end
    end
  end
end
