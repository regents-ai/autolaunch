defmodule Autolaunch.TreasurySecurityTest do
  @moduledoc """
  A treasury is judged by its setup as it is now (Sean, 9 Nov 2026, 4 a): a Safe
  fixed after a look that did not pass is verified, a report bound to an
  auction refuses a setup that differs from it, and evidence sent before the
  Safe's current setup is refused with its own reason.
  """
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{TestAutolaunchTreasuryChainClient, TreasurySecurity}

  @safe "0x9999999999999999999999999999999999999999"
  @evidence %{
    usdc: "0x" <> String.duplicate("11", 32),
    regent: "0x" <> String.duplicate("22", 32),
    outbound: "0x" <> String.duplicate("33", 32)
  }
  @four_owners [
    "0x1111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222",
    "0x3333333333333333333333333333333333333333",
    "0x4444444444444444444444444444444444444444"
  ]

  test "a Safe fixed after a look that did not pass is verified, and its report holds" do
    TestAutolaunchTreasuryChainClient.install(owners: @four_owners)

    assert {:ok, %{verification_state: :unverified, verification_reason: "safe_owner_count"}} =
             observe()

    TestAutolaunchTreasuryChainClient.install([])
    assert {:ok, %{verification_state: :verified} = fixed} = observe()
    assert {:ok, _fresh} = TreasurySecurity.revalidate_bound(fixed)
  end

  test "a bound report refuses a setup that differs from it, and takes it back once restored" do
    TestAutolaunchTreasuryChainClient.install([])
    assert {:ok, %{verification_state: :verified} = bound} = observe()

    TestAutolaunchTreasuryChainClient.install(threshold: 1)
    assert {:error, :treasury_security_changed} = TreasurySecurity.revalidate_bound(bound)

    TestAutolaunchTreasuryChainClient.install([])
    assert {:ok, _fresh} = TreasurySecurity.revalidate_bound(bound)
  end

  test "evidence sent before the Safe's current setup is refused with its own reason" do
    TestAutolaunchTreasuryChainClient.install(evidence_drift: true)
    assert {:error, :treasury_configuration_drift} = observe()
  end

  defp observe, do: Autolaunch.observe_treasury_security(@safe, @evidence, actor: %System{})
end
