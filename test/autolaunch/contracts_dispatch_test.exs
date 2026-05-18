defmodule Autolaunch.ContractsDispatchTest do
  use ExUnit.Case, async: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Contracts
  alias Autolaunch.Contracts.ActionParams
  alias Autolaunch.Contracts.Abi
  alias Autolaunch.Contracts.Dispatch

  test "job dispatch prepares the migrate transaction" do
    assert {:ok, prepared} =
             Dispatch.build_job_action(
               %{
                 chain_id: 8_453,
                 strategy_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
               },
               "strategy",
               "migrate",
               %{}
             )

    assert prepared.resource == "strategy"
    assert prepared.action == "migrate"
    assert prepared.wallet_action.to == "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  end

  test "job dispatch prepares the new settlement transactions" do
    job = %{
      job_id: "job_contracts",
      chain_id: 8_453,
      strategy_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      auction_address: "0xcccccccccccccccccccccccccccccccccccccccc",
      revenue_share_splitter_address: "0x4444444444444444444444444444444444444444",
      launch_fee_registry_address: "0x1111111111111111111111111111111111111111",
      launch_fee_vault_address: "0x2222222222222222222222222222222222222222",
      hook_address: "0x3333333333333333333333333333333333333333",
      pool_id: "0x" <> String.duplicate("a", 64)
    }

    assert {:ok, recover} =
             Dispatch.build_job_action(job, "strategy", "recover_failed_auction", %{})

    assert recover.action == "recover_failed_auction"
    assert recover.wallet_action.to == job.strategy_address

    assert {:ok, auction_currency} =
             Dispatch.build_job_action(job, "auction", "sweep_quote_token", %{})

    assert auction_currency.action == "sweep_quote_token"
    assert auction_currency.wallet_action.to == job.auction_address
    assert String.starts_with?(auction_currency.wallet_action.data, Abi.selector(:sweep_currency))

    assert {:ok, strategy_currency} =
             Dispatch.build_job_action(job, "strategy", "sweep_quote_token", %{})

    assert strategy_currency.action == "sweep_quote_token"
    assert strategy_currency.wallet_action.to == job.strategy_address

    assert String.starts_with?(
             strategy_currency.wallet_action.data,
             Abi.selector(:sweep_quote_token)
           )

    assert {:ok, auction_tokens} =
             Dispatch.build_job_action(job, "auction", "sweep_unsold_tokens", %{})

    assert auction_tokens.action == "sweep_unsold_tokens"
    assert auction_tokens.wallet_action.to == job.auction_address

    assert {:ok, splitter_acceptance} =
             Dispatch.build_job_action(job, "revenue_splitter", "accept_ownership", %{})

    assert splitter_acceptance.wallet_action.to == job.revenue_share_splitter_address

    assert {:ok, registry_acceptance} =
             Dispatch.build_job_action(job, "fee_registry", "accept_ownership", %{})

    assert registry_acceptance.wallet_action.to == job.launch_fee_registry_address

    assert {:ok, vault_acceptance} =
             Dispatch.build_job_action(job, "fee_vault", "accept_ownership", %{})

    assert vault_acceptance.wallet_action.to == job.launch_fee_vault_address

    assert {:ok, hook_acceptance} =
             Dispatch.build_job_action(job, "hook", "accept_ownership", %{})

    assert hook_acceptance.wallet_action.to == job.hook_address
  end

  test "admin prepare uses a linked contract operator wallet" do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_contract_admin = Application.get_env(:autolaunch, :contract_admin, [])
    operator_wallet = "0xB26A3609acD791e2eA3f1900619C910B45705adD"

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
      Application.put_env(:autolaunch, :contract_admin, previous_contract_admin)
    end)

    Application.put_env(:autolaunch, :contract_admin, operator_wallets: [operator_wallet])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(previous_launch,
        chain_id: 8_453,
        revenue_share_factory_address: "0x2222222222222222222222222222222222222222",
        revenue_ingress_factory_address: "0x3333333333333333333333333333333333333333"
      )
    )

    human = %HumanUser{
      wallet_address: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      wallet_addresses: [operator_wallet]
    }

    assert {:ok, %{prepared: prepared}} =
             Contracts.prepare_admin_action(
               "revenue_share_factory",
               "set_authorized_creator",
               %{
                 "account" => "0x1111111111111111111111111111111111111111",
                 "enabled" => "true"
               },
               human
             )

    assert prepared.expected_signer == String.downcase(operator_wallet)
    assert prepared.wallet_action.expected_signer == prepared.expected_signer
  end

  test "prepared transaction identity includes expected signer" do
    params = %{"resource_id" => "subject:alpha"}

    assert {:ok, first} =
             ActionParams.prepare_tx(
               8_453,
               "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
               "0x1234",
               "subject",
               "stake",
               params,
               expected_signer: "0x1111111111111111111111111111111111111111"
             )

    assert {:ok, second} =
             ActionParams.prepare_tx(
               8_453,
               "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
               "0x1234",
               "subject",
               "stake",
               params,
               expected_signer: "0x2222222222222222222222222222222222222222"
             )

    refute first.action_id == second.action_id
    refute first.idempotency_key == second.idempotency_key
    assert first.wallet_action.expected_signer == "0x1111111111111111111111111111111111111111"
    assert second.wallet_action.expected_signer == "0x2222222222222222222222222222222222222222"
  end

  test "prepared transaction rejects malformed hex value" do
    assert {:error, :invalid_value} =
             ActionParams.prepare_tx(
               8_453,
               "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
               "0x1234",
               "subject",
               "stake",
               %{"resource_id" => "subject:alpha"},
               value: "0x-1"
             )
  end

  test "admin prepare rejects a wallet outside the contract operator list" do
    previous_contract_admin = Application.get_env(:autolaunch, :contract_admin, [])
    operator_wallet = "0xB26A3609acD791e2eA3f1900619C910B45705adD"

    on_exit(fn ->
      Application.put_env(:autolaunch, :contract_admin, previous_contract_admin)
    end)

    Application.put_env(:autolaunch, :contract_admin, operator_wallets: [operator_wallet])

    human = %HumanUser{
      wallet_address: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      wallet_addresses: []
    }

    assert {:error, :operator_required} =
             Contracts.prepare_admin_action(
               "revenue_share_factory",
               "set_authorized_creator",
               %{
                 "account" => "0x1111111111111111111111111111111111111111",
                 "enabled" => "true"
               },
               human
             )
  end

  test "subject dispatch returns stable invalid address and ingress errors" do
    subject = %{
      chain_id: 8_453,
      subject_id: "0x" <> String.duplicate("a", 64),
      ingress_accounts: [%{address: "0x1111111111111111111111111111111111111111"}]
    }

    assert {:error, :invalid_address} =
             Dispatch.build_subject_action(
               subject,
               %{address: "0x2222222222222222222222222222222222222222"},
               "ingress_account",
               "set_label",
               %{"ingress_address" => "bad-address", "label" => "Ops"},
               %{ingress_factory_address: "0x3333333333333333333333333333333333333333"}
             )

    assert {:error, :ingress_not_found} =
             Dispatch.build_subject_action(
               subject,
               %{address: "0x2222222222222222222222222222222222222222"},
               "ingress_account",
               "sweep",
               %{"ingress_address" => "0x9999999999999999999999999999999999999999"},
               %{ingress_factory_address: "0x3333333333333333333333333333333333333333"}
             )
  end

  test "removed fee mutation actions stay unsupported in dispatch" do
    job = %{
      chain_id: 8_453,
      launch_fee_registry_address: "0x1111111111111111111111111111111111111111",
      launch_fee_vault_address: "0x2222222222222222222222222222222222222222",
      pool_id: "0x" <> String.duplicate("a", 64)
    }

    subject = %{
      chain_id: 8_453,
      splitter_address: "0x3333333333333333333333333333333333333333"
    }

    assert {:error, :unsupported_action} =
             Dispatch.build_job_action(job, "fee_registry", "set_hook_enabled", %{
               "enabled" => "false"
             })

    assert {:error, :unsupported_action} =
             Dispatch.build_job_action(job, "fee_vault", "set_hook", %{
               "hook" => "0x4444444444444444444444444444444444444444"
             })

    assert {:error, :unsupported_action} =
             Dispatch.build_job_action(job, "fee_vault", "withdraw_treasury", %{
               "amount" => "7"
             })

    assert {:error, :unsupported_action} =
             Dispatch.build_subject_action(
               subject,
               %{address: "0x5555555555555555555555555555555555555555"},
               "splitter",
               "set_protocol_skim_bps",
               %{"skim_bps" => "250"},
               %{ingress_factory_address: "0x6666666666666666666666666666666666666666"}
             )
  end

  test "prepared action selectors match Foundry ABI artifacts" do
    assert Abi.selector(:withdraw_regent_share) ==
             artifact_selector(
               "contracts/out/LaunchFeeVault.sol/LaunchFeeVault.json",
               "withdrawRegentShare"
             )
  end

  test "owned ABI modules do not include stale contract functions" do
    assert_raise KeyError, fn ->
      Abi.selector(:max_currency_amount_for_lp)
    end

    assert_raise KeyError, fn ->
      Autolaunch.RegentStaking.Abi.selector(:staker_share_bps)
    end

    assert Autolaunch.RegentStaking.Abi.selector(:revenue_share_supply_denominator) ==
             artifact_selector(
               "contracts/out/RegentRevenueStaking.sol/RegentRevenueStaking.json",
               "revenueShareSupplyDenominator"
             )

    assert artifact_function?(
             "contracts/out/RegentRevenueStaking.sol/RegentRevenueStaking.json",
             "revenueShareSupplyDenominator"
           )
  end

  defp artifact_selector(path, name) do
    artifact =
      path
      |> File.read!()
      |> Jason.decode!()

    signature =
      artifact
      |> Map.fetch!("abi")
      |> Enum.find(fn entry ->
        entry["type"] == "function" and entry["name"] == name
      end)
      |> function_signature()

    "0x" <> Map.fetch!(Map.fetch!(artifact, "methodIdentifiers"), signature)
  end

  defp artifact_function?(path, name) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("abi")
    |> Enum.any?(fn entry ->
      entry["type"] == "function" and entry["name"] == name
    end)
  end

  defp function_signature(%{"name" => name, "inputs" => inputs}) do
    types =
      inputs
      |> Enum.map(&Map.fetch!(&1, "type"))
      |> Enum.join(",")

    "#{name}(#{types})"
  end
end
