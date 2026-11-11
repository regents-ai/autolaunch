defmodule Autolaunch.CoveredCalls.DeploymentTest do
  @moduledoc """
  The markets file that switches covered calls on with CoveredCallsV2
  (`contracts/covered-calls-v2/deploy/site-markets.json`) reads as the site
  reads it, and names the contract the deploy packet places on Base for AMZNc,
  for the stock that contract is built with. It reads the packet's predicted
  address until the deploy lands; recording the deploy in `deployed.json`
  moves it to that record (the packet's README, "After it lands").
  """
  use ExUnit.Case, async: true

  alias Autolaunch.CoveredCalls.Deployment

  @deploy Path.expand("../../../../contracts/covered-calls-v2/deploy", __DIR__)

  test "the markets file names the deploy packet's AMZNc contract on Base" do
    {:ok, config} = Deployment.load(Path.join(@deploy, "site-markets.json"))
    packet = @deploy |> Path.join("packet.json") |> File.read!() |> Jason.decode!()

    assert config.chain_id == packet["chain_id"]
    assert [market] = config.markets
    assert market.symbol == packet["market"]
    assert market.contract == String.downcase(packet["create2"]["predicted_address"])
    assert market.stock == String.downcase(hd(packet["constructor"])["value"])
  end
end
