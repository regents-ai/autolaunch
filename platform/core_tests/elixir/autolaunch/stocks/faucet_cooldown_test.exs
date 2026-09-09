defmodule Autolaunch.Stocks.FaucetCooldownTest do
  use Autolaunch.DataCase, async: true

  alias Autolaunch.Stocks.{FaucetCooldown, FaucetGrant}

  @wallet "0x1111111111111111111111111111111111111111"
  @other "0x2222222222222222222222222222222222222222"

  test "a second grant of the same asset to the same wallet inside the window is refused" do
    send = fn -> {:ok, :sent} end

    assert {:ok, :sent} = FaucetCooldown.grant(@wallet, "regent", 3_600, send)

    assert {:ok, %FaucetGrant{granted_at: granted_at}} =
             Ash.read_one(
               Ash.Query.for_read(FaucetGrant, :latest, %{wallet: @wallet, asset: "regent"},
                 actor: %Autolaunch.Actors.System{}
               )
             )

    opens_at = DateTime.add(granted_at, 3_600, :second)
    expected = FaucetCooldown.refusal(opens_at)

    assert expected =~
             ~r/^That test asset was already sent to this wallet recently; try again after \d\d:\d\d UTC\.$/

    # The press still performs the check, and the send is not attempted.
    assert {:error, ^expected} =
             FaucetCooldown.grant(@wallet, "regent", 3_600, fn ->
               flunk("sent inside the window")
             end)

    # Another asset, and another wallet, each have their own window.
    assert {:ok, :sent} = FaucetCooldown.grant(@wallet, "usdc", 3_600, send)
    assert {:ok, :sent} = FaucetCooldown.grant(@other, "regent", 3_600, send)

    # Once the window has passed the same asset goes out again, and the new
    # grant starts a new window of its own.
    Process.sleep(1_100)
    assert {:ok, :sent} = FaucetCooldown.grant(@wallet, "regent", 1, send)

    assert {:error, "That test asset was already sent" <> _rest} =
             FaucetCooldown.grant(@wallet, "regent", 1, send)
  end

  test "a failed send records nothing, and a window of zero neither checks nor records" do
    assert {:error, "The fork answered unexpectedly."} =
             FaucetCooldown.grant(@wallet, "regent", 3_600, fn ->
               {:error, "The fork answered unexpectedly."}
             end)

    assert {:ok, nil} =
             Ash.read_one(
               Ash.Query.for_read(FaucetGrant, :latest, %{wallet: @wallet, asset: "regent"},
                 actor: %Autolaunch.Actors.System{}
               )
             )

    assert {:ok, :sent} = FaucetCooldown.grant(@wallet, "regent", 0, fn -> {:ok, :sent} end)
    assert {:ok, :sent} = FaucetCooldown.grant(@wallet, "regent", 0, fn -> {:ok, :sent} end)

    assert {:ok, nil} =
             Ash.read_one(
               Ash.Query.for_read(FaucetGrant, :latest, %{wallet: @wallet, asset: "regent"},
                 actor: %Autolaunch.Actors.System{}
               )
             )
  end
end
