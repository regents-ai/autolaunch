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
