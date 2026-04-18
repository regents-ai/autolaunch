defmodule Autolaunch.Launch.ParamsTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Launch.Params

  test "preview attrs normalize string keys into canonical atom-keyed params" do
    assert Params.preview_attrs(%{
             "agent_id" => "84532:42",
             "token_name" => "Atlas Coin",
             "token_symbol" => "ATLAS",
             "minimum_raise_usdc" => "250.0",
             "launch_notes" => "ready",
             "ignored" => "skip"
           }) == %{
             agent_id: "84532:42",
             token_name: "Atlas Coin",
             token_symbol: "ATLAS",
             minimum_raise_usdc: "250.0",
             launch_notes: "ready"
           }
  end

  test "bid registration attrs keep only the transaction hash" do
    assert Params.bid_registration_attrs(%{
             "amount" => "25.0",
             "max_price" => "0.005",
             "tx_hash" => "0x1234"
           }) == %{tx_hash: "0x1234"}
  end
end
