defmodule Autolaunch.ContractsTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Contracts
  alias Autolaunch.Launch
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @subject_id "0x" <> String.duplicate("1a", 32)
  @splitter "0x9999999999999999999999999999999999999999"
  @token "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @ingress "0x7777777777777777777777777777777777777777"
  @registry "0x3333333333333333333333333333333333333333"
  @wallet "0x1111111111111111111111111111111111111111"
  @wrong_wallet "0x2222222222222222222222222222222222222222"

  setup do
    previous_adapter = Application.get_env(:autolaunch, :cca_rpc_adapter)

    Application.put_env(:autolaunch, :cca_rpc_adapter, __MODULE__.FakeRpc)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_adapter)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:contracts-helper", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Contracts Owner"
      })

    {:ok, wrong_human} =
      Accounts.upsert_human_by_privy_id("did:privy:contracts-helper-wrong", %{
        "wallet_address" => @wrong_wallet,
        "wallet_addresses" => [@wrong_wallet],
        "display_name" => "Wrong Wallet"
      })

    now = DateTime.utc_now()
    nonce = "nonce-#{System.unique_integer([:positive])}"

    {:ok, job} =
      %Job{}
      |> Job.create_changeset(%{
        job_id: "job_contracts_helper",
        owner_address: @wallet,
        agent_id: "84532:42",
        token_name: "Atlas Coin",
        token_symbol: "ATLAS",
        agent_safe_address: @wallet,
        network: "base-sepolia",
        chain_id: 84_532,
        status: "ready",
        step: "ready",
        total_supply: "1000",
        message: "signed",
        siwa_nonce: nonce,
        siwa_signature: "sig",
        issued_at: now
      })
      |> Repo.insert()

    job =
      job
      |> Job.update_changeset(%{
        token_address: @token,
        strategy_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        vesting_wallet_address: "0xdddddddddddddddddddddddddddddddddddddddd",
        subject_registry_address: @registry,
        revenue_share_splitter_address: @splitter,
        default_ingress_address: @ingress,
        subject_id: @subject_id
      })
      |> Repo.update!()

    %{human: human, wrong_human: wrong_human, job: job}
  end

  test "job_state_from_response enforces owner scoping", %{human: human, wrong_human: wrong_human} do
    assert {:ok, response} = Launch.get_job_response("job_contracts_helper")

    assert {:ok, %{job: %{job_id: "job_contracts_helper"}}} =
             Contracts.job_state_from_response(response, human)

    assert {:error, :forbidden} = Contracts.job_state_from_response(response, wrong_human)
    assert {:error, :unauthorized} = Contracts.job_state_from_response(response, nil)
  end

  test "subject_state loads the shared subject view and enforces owner scoping", %{
    human: human,
    wrong_human: wrong_human
  } do
    assert {:ok, %{subject: subject, registry: registry}} =
             Contracts.subject_state(@subject_id, human)

    assert subject.subject_id == @subject_id
    assert subject.splitter_address == @splitter
    assert subject.eligible_revenue_share_bps == 10_000
    assert subject.gross_inflow_usdc_raw == 125_000_000
    assert subject.treasury_reserved_usdc_raw == 12_000_000
    assert subject.share_change_history == []
    assert registry.address == @registry

    assert {:error, :forbidden} = Contracts.subject_state(@subject_id, wrong_human)
    assert {:error, :unauthorized} = Contracts.subject_state(@subject_id, nil)
  end

  test "prepare_job_action enforces owner scoping", %{human: human, wrong_human: wrong_human} do
    assert {:ok, %{job_id: "job_contracts_helper", prepared: prepared}} =
             Contracts.prepare_job_action(
               "job_contracts_helper",
               "strategy",
               "migrate",
               %{},
               human
             )

    assert prepared.resource == "strategy"
    assert prepared.action == "migrate"

    assert {:error, :forbidden} =
             Contracts.prepare_job_action(
               "job_contracts_helper",
               "strategy",
               "migrate",
               %{},
               wrong_human
             )

    assert {:error, :unauthorized} =
             Contracts.prepare_job_action("job_contracts_helper", "strategy", "migrate", %{}, nil)
  end

  test "prepare_subject_action enforces owner scoping", %{human: human, wrong_human: wrong_human} do
    assert {:ok, %{subject_id: @subject_id, prepared: prepared}} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "set_paused",
               %{"paused" => "true"},
               human
             )

    assert prepared.resource == "splitter"
    assert prepared.action == "set_paused"

    assert {:error, :forbidden} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "set_paused",
               %{"paused" => "true"},
               wrong_human
             )

    assert {:error, :unauthorized} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "set_paused",
               %{"paused" => "true"},
               nil
             )
  end

  test "prepare_subject_action validates eligible share proposals against splitter rules", %{
    human: human
  } do
    assert {:error, :eligible_share_too_low} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "propose_eligible_revenue_share",
               %{"share_bps" => "999"},
               human
             )

    assert {:error, :eligible_share_too_high} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "propose_eligible_revenue_share",
               %{"share_bps" => "10001"},
               human
             )

    assert {:error, :eligible_share_step_too_large} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "propose_eligible_revenue_share",
               %{"share_bps" => "7000"},
               human
             )

    assert {:ok, %{prepared: prepared}} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "propose_eligible_revenue_share",
               %{"share_bps" => "8000"},
               human
             )

    assert prepared.action == "propose_eligible_revenue_share"
    assert prepared.params == %{share_bps: "8000"}
  end

  test "removed fee mutation actions stay unavailable through the contracts context", %{
    human: human
  } do
    assert {:error, :unsupported_action} =
             Contracts.prepare_job_action(
               "job_contracts_helper",
               "fee_registry",
               "set_hook_enabled",
               %{"enabled" => "false"},
               human
             )

    assert {:error, :unsupported_action} =
             Contracts.prepare_job_action(
               "job_contracts_helper",
               "fee_vault",
               "set_hook",
               %{"hook" => "0x4444444444444444444444444444444444444444"},
               human
             )

    assert {:error, :unsupported_action} =
             Contracts.prepare_subject_action(
               @subject_id,
               "splitter",
               "set_protocol_skim_bps",
               %{"skim_bps" => "250"},
               human
             )
  end

  defmodule FakeRpc do
    @splitter "0x9999999999999999999999999999999999999999"
    @token "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    @subject_registry "0x3333333333333333333333333333333333333333"
    @usdc "0x5555555555555555555555555555555555555555"
    @wallet "0x1111111111111111111111111111111111111111"

    def block_number(_chain_id, _opts), do: {:ok, 1}

    def eth_call(84_532, @splitter, data, _opts) do
      case String.slice(data, 0, 10) do
        "0x817b1cd2" -> {:ok, uint(250 * Integer.pow(10, 18))}
        "0x549b5d48" -> {:ok, uint(10_000)}
        "0xb663660a" -> {:ok, uint(0)}
        "0x8c37a52f" -> {:ok, uint(0)}
        "0x5cc76060" -> {:ok, uint(0)}
        "0x8064d80c" -> {:ok, uint(125 * Integer.pow(10, 6))}
        "0x1aa91287" -> {:ok, uint(10 * Integer.pow(10, 6))}
        "0x08c23673" -> {:ok, uint(90 * Integer.pow(10, 6))}
        "0xddffd82a" -> {:ok, uint(25 * Integer.pow(10, 6))}
        "0x966ed108" -> {:ok, uint(25 * Integer.pow(10, 6))}
        "0xe76bcce9" -> {:ok, uint(12 * Integer.pow(10, 6))}
        "0x76459dd5" -> {:ok, uint(10 * Integer.pow(10, 6))}
        "0x5f78d5f4" -> {:ok, uint(1 * Integer.pow(10, 6))}
        "0x60217267" -> {:ok, uint(12 * Integer.pow(10, 18))}
        "0xb026ee79" -> {:ok, uint(5 * Integer.pow(10, 6))}
        "0x05e1fd68" -> {:ok, uint(4 * Integer.pow(10, 18))}
        "0x05f15537" -> {:ok, uint(3 * Integer.pow(10, 18))}
        "0xcfb3d0aa" -> {:ok, uint(8 * Integer.pow(10, 18))}
        "0x66ffb8de" -> {:ok, uint(6 * Integer.pow(10, 18))}
        "0x3e413bee" -> {:ok, address(@usdc)}
        "0x8da5cb5b" -> {:ok, address(@wallet)}
        _ -> {:error, :unsupported_call}
      end
    end

    def eth_call(84_532, @token, "0x70a08231" <> _rest, _opts),
      do: {:ok, uint(90 * Integer.pow(10, 18))}

    def eth_call(84_532, @usdc, "0x70a08231" <> _rest, _opts),
      do: {:ok, uint(7 * Integer.pow(10, 6))}

    def eth_call(84_532, @subject_registry, "0x41c2ab07" <> data, _opts) do
      wallet =
        data
        |> String.slice(-40, 40)
        |> then(&("0x" <> String.downcase(&1)))

      {:ok, bool(wallet == @wallet)}
    end

    def eth_call(84_532, @subject_registry, "0x8da5cb5b", _opts), do: {:ok, address(@wallet)}
    def eth_call(84_532, @subject_registry, "0x0f3f0a8f" <> _rest, _opts), do: {:ok, uint(0)}

    def eth_call(_chain_id, _to, _data, _opts), do: {:error, :unsupported_call}

    def tx_receipt(_chain_id, _tx_hash, _opts), do: {:ok, nil}
    def tx_by_hash(_chain_id, _tx_hash, _opts), do: {:ok, nil}
    def get_logs(_chain_id, _filter, _opts), do: {:ok, []}

    defp uint(value), do: "0x" <> (value |> Integer.to_string(16) |> String.pad_leading(64, "0"))

    defp address(value) do
      "0x" <> String.pad_leading(String.slice(value, 2..-1//1), 64, "0")
    end

    defp bool(true), do: "0x" <> String.pad_leading("1", 64, "0")
    defp bool(false), do: "0x" <> String.pad_leading("0", 64, "0")
  end
end
