defmodule Autolaunch.CoveredCalls.DeploymentTest do
  @moduledoc """
  The markets file production switches covered calls on with
  (`contracts/covered-calls/deploy/site-markets.json`) reads as the site reads
  it, and names the contract the deployment record says landed on Base, for the
  stock and USDC that contract was built with.
  """
  use ExUnit.Case, async: true

  alias Autolaunch.CoveredCalls.Deployment

  @deploy Path.expand("../../../../contracts/covered-calls/deploy", __DIR__)

  test "the production markets file names the deployed AMZNc contract on Base" do
    {:ok, config} = Deployment.load(Path.join(@deploy, "site-markets.json"))
    deployed = @deploy |> Path.join("deployed.json") |> File.read!() |> Jason.decode!()

    assert config.chain_id == deployed["chain_id"]
    assert [market] = config.markets
    assert market.symbol == deployed["market"]
    assert market.contract == String.downcase(deployed["address"])
    assert market.stock == String.downcase(deployed["checks_on_base"]["reads"]["stock()"])
  end
end
