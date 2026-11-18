defmodule AutolaunchWeb.ToolManifest do
  @moduledoc """
  The WebMCP tools this site offers right now. `priv/tool_manifest.json` is the
  site's own set, the one the pages' script is built with
  (`assets/js/public_tools.ts`). While covered calls, Exposure, Earn, agent
  bids or agent Robinhood bids are on, the tools in
  `priv/covered_calls_tools.json`, `priv/exposure_tools.json`,
  `priv/earn_tools.json`, `priv/agent_bids_tools.json` or
  `priv/agent_robinhood_bids_tools.json` join it, and the root layout hands the page those tools (`page_tools/0`), so the page registers exactly the tools
  `/capabilities.json`, the agent guides and the tools dialog list. Off, nothing
  about them reaches a page, the script or any document.
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

  @doc "The features that are on, by name."
  def features do
    [
      {"covered_calls", Autolaunch.CoveredCalls.Deployment.enabled?()},
      {"exposure", Autolaunch.Exposure.Deployment.enabled?()},
      {"earn", Autolaunch.Earn.Catalog.enabled?()},
      {"agent_bids", Autolaunch.AgentBid.enabled?()},
      {"agent_robinhood_bids", Autolaunch.AgentRobinhoodBid.enabled?()}
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

    if("covered_calls" in on, do: @covered_calls, else: []) ++
      if("exposure" in on, do: @exposure, else: []) ++
      if("earn" in on, do: @earn, else: []) ++
      if("agent_bids" in on, do: @agent_bids, else: []) ++
      if("agent_robinhood_bids" in on, do: @agent_robinhood_bids, else: [])
  end
end
