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

  # Every feature's tools, by the name of the file in priv that holds them.
  @tools (for path <- Path.wildcard(Application.app_dir(:autolaunch, "priv/*_tools.json")),
              into: %{} do
            @external_resource path
            {Path.basename(path), path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")}
          end)

  @doc "The features that are on, by name."
  def features, do: for({module, name, _file} <- switched(), module.enabled?(), do: name)

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
    for {module, _name, file} <- switched(),
        module.enabled?(),
        tool <- Map.fetch!(@tools, file),
        do: tool
  end

  # Each feature, in the order the page is handed its tools: the module whose
  # `enabled?/0` switches it, its name and the file in priv that holds its
  # tools. Named inside a function, the modules are only called at run time,
  # so this module does not compile against them.
  defp switched do
    [
      {Autolaunch.CoveredCalls.Deployment, "covered_calls", "covered_calls_tools.json"},
      {Autolaunch.Exposure.Deployment, "exposure", "exposure_tools.json"},
      {Autolaunch.Earn.Catalog, "earn", "earn_tools.json"},
      {Autolaunch.AgentBid, "agent_bids", "agent_bids_tools.json"},
      {Autolaunch.AgentRobinhoodBid, "agent_robinhood_bids", "agent_robinhood_bids_tools.json"},
      {Autolaunch.AgentLaunch, "agent_launches", "agent_launches_tools.json"},
      {Autolaunch.AgentFinish, "agent_finish", "agent_finish_tools.json"},
      {Autolaunch.AgentStake, "agent_staking", "agent_stake_tools.json"},
      {Autolaunch.AgentSwap, "agent_swaps", "agent_swap_tools.json"},
      {Autolaunch.AgentPayment, "agent_payments", "agent_payment_tools.json"}
    ]
  end
end
