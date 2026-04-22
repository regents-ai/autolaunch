defmodule Autolaunch.ContractsDispatchTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Contracts.Dispatch

  test "job dispatch prepares the migrate transaction" do
    assert {:ok, prepared} =
             Dispatch.build_job_action(
               %{
                 chain_id: 84_532,
                 strategy_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
               },
               "strategy",
               "migrate",
               %{}
             )

    assert prepared.resource == "strategy"
    assert prepared.action == "migrate"
    assert prepared.tx_request.to == "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  end

  test "job dispatch prepares the new settlement transactions" do
    job = %{
      chain_id: 84_532,
      strategy_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      auction_address: "0xcccccccccccccccccccccccccccccccccccccccc",
      launch_fee_registry_address: "0x1111111111111111111111111111111111111111",
      launch_fee_vault_address: "0x2222222222222222222222222222222222222222",
      hook_address: "0x3333333333333333333333333333333333333333"
    }

    assert {:ok, recover} =
             Dispatch.build_job_action(job, "strategy", "recover_failed_auction", %{})

    assert recover.action == "recover_failed_auction"
    assert recover.tx_request.to == job.strategy_address

    assert {:ok, auction_currency} =
             Dispatch.build_job_action(job, "auction", "sweep_currency", %{})

    assert auction_currency.action == "sweep_currency"
    assert auction_currency.tx_request.to == job.auction_address

    assert {:ok, auction_tokens} =
             Dispatch.build_job_action(job, "auction", "sweep_unsold_tokens", %{})

    assert auction_tokens.action == "sweep_unsold_tokens"
    assert auction_tokens.tx_request.to == job.auction_address

    assert {:ok, registry_acceptance} =
             Dispatch.build_job_action(job, "fee_registry", "accept_ownership", %{})

    assert registry_acceptance.tx_request.to == job.launch_fee_registry_address

    assert {:ok, vault_acceptance} =
             Dispatch.build_job_action(job, "fee_vault", "accept_ownership", %{})

    assert vault_acceptance.tx_request.to == job.launch_fee_vault_address

    assert {:ok, hook_acceptance} =
             Dispatch.build_job_action(job, "hook", "accept_ownership", %{})

    assert hook_acceptance.tx_request.to == job.hook_address
  end

  test "subject dispatch returns stable invalid address and ingress errors" do
    subject = %{
      chain_id: 84_532,
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
      chain_id: 84_532,
      launch_fee_registry_address: "0x1111111111111111111111111111111111111111",
      launch_fee_vault_address: "0x2222222222222222222222222222222222222222",
      pool_id: "0x" <> String.duplicate("a", 64)
    }

    subject = %{
      chain_id: 84_532,
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
             Dispatch.build_subject_action(
               subject,
               %{address: "0x5555555555555555555555555555555555555555"},
               "splitter",
               "set_protocol_skim_bps",
               %{"skim_bps" => "250"},
               %{ingress_factory_address: "0x6666666666666666666666666666666666666666"}
             )
  end
end
