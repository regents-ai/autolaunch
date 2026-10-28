defmodule AutolaunchWeb.ToolManifest do
  @moduledoc """
  The WebMCP tools this site offers right now, from `priv/tool_manifest.json`,
  the file the pages register them from (`assets/js/public_tools.ts`).

  An entry tagged with a `feature` is offered only while that feature is on
  here, and `prepare_agent_request` names only the signed tools offered. The
  root layout tells the page which features are on (`features/0`), so the
  page registers exactly the tools `/capabilities`, the agent guides and the
  tools dialog list.
  """

  @path Application.app_dir(:autolaunch, "priv/tool_manifest.json")
  @external_resource @path
  @manifest @path |> File.read!() |> Jason.decode!()

  @doc "The features that are on, by the names manifest entries use."
  def features,
    do: if(Autolaunch.CoveredCalls.Deployment.enabled?(), do: ["covered_calls"], else: [])

  @doc "The manifest, with only the tools offered now."
  def current do
    on = features()
    tools = Enum.filter(@manifest["tools"], &(Map.get(&1, "feature") in [nil | on]))
    offered = MapSet.new(tools, & &1["name"])

    %{@manifest | "tools" => Enum.map(tools, &operations(&1, offered))}
  end

  @doc "The tools offered now."
  def tools, do: current()["tools"]

  defp operations(%{"name" => "prepare_agent_request"} = tool, offered),
    do:
      update_in(
        tool,
        ["input_schema", "properties", "operation", "enum"],
        &Enum.filter(&1, fn name -> name in offered end)
      )

  defp operations(tool, _offered), do: tool
end
