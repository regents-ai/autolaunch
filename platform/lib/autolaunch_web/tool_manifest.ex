defmodule AutolaunchWeb.ToolManifest do
  @moduledoc """
  The WebMCP tools this site offers right now. `priv/tool_manifest.json` is the
  site's own set, the one the pages' script is built with
  (`assets/js/public_tools.ts`). While covered calls, Exposure, Earn, agent
  bids, agent Robinhood bids, agent launches, agent finishes, agent staking,
  agent swaps or agent payments are on, the tools in
  `priv/covered_calls_tools.json`, `priv/exposure_tools.json`,
  `priv/earn_tools.json`, `priv/agent_bids_tools.json`,
  `priv/agent_robinhood_bids_tools.json`, `priv/agent_launches_tools.json`,
  `priv/agent_finish_tools.json`, `priv/agent_stake_tools.json`,
  `priv/agent_swap_tools.json` or `priv/agent_payment_tools.json` join it, and
  the root layout hands the page those tools (`page_tools/0`), so the page
  registers exactly the tools `/capabilities.json`, the agent guides and the
  tools dialog list. Off, nothing about them reaches a page, the script or any
  document.
  """

  @path Application.app_dir(:autolaunch, "priv/tool_manifest.json")
  @external_resource @path
  @manifest @path |> File.read!() |> Jason.decode!()

  @covered_calls_path Application.app_dir(:autolaunch, "priv/covered_calls_tools.json")
  @external_resource @covered_calls_path
  @covered_calls @covered_calls_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @exposure_path Application.app_dir(:autolaunch, "priv/exposure_tools.json")
  @external_resource @exposure_path
  @exposure @exposure_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @earn_path Application.app_dir(:autolaunch, "priv/earn_tools.json")
  @external_resource @earn_path
  @earn @earn_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @agent_bids_path Application.app_dir(:autolaunch, "priv/agent_bids_tools.json")
  @external_resource @agent_bids_path
  @agent_bids @agent_bids_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @agent_robinhood_bids_path Application.app_dir(
                               :autolaunch,
                               "priv/agent_robinhood_bids_tools.json"
                             )
  @external_resource @agent_robinhood_bids_path
  @agent_robinhood_bids @agent_robinhood_bids_path
                        |> File.read!()
                        |> Jason.decode!()
                        |> Map.fetch!("tools")

  @agent_launches_path Application.app_dir(:autolaunch, "priv/agent_launches_tools.json")
  @external_resource @agent_launches_path
  @agent_launches @agent_launches_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @agent_finish_path Application.app_dir(:autolaunch, "priv/agent_finish_tools.json")
  @external_resource @agent_finish_path
  @agent_finish @agent_finish_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @agent_stake_path Application.app_dir(:autolaunch, "priv/agent_stake_tools.json")
  @external_resource @agent_stake_path
  @agent_stake @agent_stake_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @agent_swap_path Application.app_dir(:autolaunch, "priv/agent_swap_tools.json")
  @external_resource @agent_swap_path
  @agent_swap @agent_swap_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @agent_payment_path Application.app_dir(:autolaunch, "priv/agent_payment_tools.json")
  @external_resource @agent_payment_path
  @agent_payment @agent_payment_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  # Each feature's tools, in the order the page is handed them.
  @page_tools [
    {"covered_calls", @covered_calls},
    {"exposure", @exposure},
    {"earn", @earn},
    {"agent_bids", @agent_bids},
    {"agent_robinhood_bids", @agent_robinhood_bids},
    {"agent_launches", @agent_launches},
    {"agent_finish", @agent_finish},
    {"agent_staking", @agent_stake},
    {"agent_swaps", @agent_swap},
    {"agent_payments", @agent_payment}
  ]

  @doc "The features that are on, by name."
  def features do
    [
      {"covered_calls", Autolaunch.CoveredCalls.Deployment.enabled?()},
      {"exposure", Autolaunch.Exposure.Deployment.enabled?()},
      {"earn", Autolaunch.Earn.Catalog.enabled?()},
      {"agent_bids", Autolaunch.AgentBid.enabled?()},
      {"agent_robinhood_bids", Autolaunch.AgentRobinhoodBid.enabled?()},
      {"agent_launches", Autolaunch.AgentLaunch.enabled?()},
      {"agent_finish", Autolaunch.AgentFinish.enabled?()},
      {"agent_staking", Autolaunch.AgentStake.enabled?()},
      {"agent_swaps", Autolaunch.AgentSwap.enabled?()},
      {"agent_payments", Autolaunch.AgentPayment.enabled?()}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  @doc "The manifest with the tools offered now: the site's own, exactly, while no feature is on."
  def current do
    case page_tools() do
      [] ->
        @manifest

      added ->
        %{@manifest | "tools" => @manifest["tools"] ++ added}
    end
  end

  @doc "The tools offered now."
  def tools, do: current()["tools"]

  @doc "The tools the page is handed beside the ones its script already knows: none while every feature is off."
  def page_tools do
    on = features()
    for {feature, tools} <- @page_tools, feature in on, tool <- tools, do: tool
  end
end
