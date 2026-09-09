defmodule Autolaunch.Stocks.FeeAdminActionsTest do
  use ExUnit.Case, async: true

  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.FeeAdminActions

  @abi "../../../../contracts/abi/stocks-launchpad-v1.json"
       |> Path.expand(__DIR__)
       |> File.read!()
       |> Jason.decode!()

  @config %{abis: %{"launchpad" => @abi}}
  @administrator "0x1111111111111111111111111111111111111111"
  @stranger "0x2222222222222222222222222222222222222222"
  @splitter "0x5555555555555555555555555555555555555555"

  @snapshot %{
    launchpad: "0x7777777777777777777777777777777777777777",
    launch_id: 7,
    config: %{
      version: 3,
      splitter: nil,
      subject_bps: 0,
      administrator: @administrator,
      proposed_administrator: nil
    },
    splitter: :verified
  }

  test "a wallet that is not the fee administrator is refused before any envelope exists" do
    assert {:error, %Ash.Error.Invalid.Unavailable{reason: :not_fee_administrator}} =
             FeeAdminActions.plan(
               :configure_subject,
               %{"splitter" => @splitter},
               @snapshot,
               @stranger,
               @config
             )

    assert {:error, %Ash.Error.Invalid.Unavailable{reason: :not_proposed_administrator}} =
             FeeAdminActions.plan(:accept_administrator, %{}, @snapshot, @stranger, @config)
  end

  test "the administrator's configureSubject carries the splitter and the current version" do
    assert {:ok, plan} =
             FeeAdminActions.plan(
               :configure_subject,
               %{"splitter" => @splitter},
               @snapshot,
               @administrator,
               @config
             )

    assert plan.data ==
             LabAbi.selector("configureSubject(uint256,address,uint32)") <>
               String.pad_leading("7", 64, "0") <>
               String.pad_leading(String.trim_leading(@splitter, "0x"), 64, "0") <>
               String.pad_leading("3", 64, "0")

    assert plan.expected_version == 3
    assert plan.splitter == @splitter
  end

  test "an empty destination turns the lane off with the zero address" do
    assert {:ok, plan} =
             FeeAdminActions.plan(
               :configure_subject,
               %{"splitter" => ""},
               @snapshot,
               @administrator,
               @config
             )

    assert plan.splitter == nil
    assert String.slice(plan.data, 10 + 64, 64) == String.duplicate("0", 64)
  end

  test "a retargeted lane needs an authentic Agent splitter" do
    assert {:error, %Ash.Error.Invalid.Unavailable{reason: :subject_splitter_unrecognised}} =
             FeeAdminActions.plan(
               :configure_subject,
               %{"splitter" => @splitter},
               %{@snapshot | splitter: :unverified},
               @administrator,
               @config
             )
  end
end
