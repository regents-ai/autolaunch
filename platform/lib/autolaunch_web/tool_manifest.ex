defmodule AutolaunchWeb.ToolManifest do
  @moduledoc """
  The WebMCP tools this site offers right now. `priv/tool_manifest.json` is the
  site's own set, the one the pages' script is built with
  (`assets/js/public_tools.ts`). While covered calls are on, the tools in
  `priv/covered_calls_tools.json` join it, their signed tools join
  `prepare_agent_request`'s operations, and the root layout hands the page
  those tools (`page_tools/0`), so the page registers exactly the tools
  `/capabilities`, the agent guides and the tools dialog list. Off, nothing
  about them reaches a page, the script or any document.
  """

  @path Application.app_dir(:autolaunch, "priv/tool_manifest.json")
  @external_resource @path
  @manifest @path |> File.read!() |> Jason.decode!()

  @covered_calls_path Application.app_dir(:autolaunch, "priv/covered_calls_tools.json")
  @external_resource @covered_calls_path
  @covered_calls @covered_calls_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @doc "The features that are on, by name."
  def features,
    do: if(Autolaunch.CoveredCalls.Deployment.enabled?(), do: ["covered_calls"], else: [])

  @doc "The manifest with the tools offered now: the site's own, exactly, while no feature is on."
  def current do
    case page_tools() do
      [] ->
        @manifest

      added ->
        %{@manifest | "tools" => Enum.map(@manifest["tools"], &operations(&1, added)) ++ added}
    end
  end

  @doc "The tools offered now."
  def tools, do: current()["tools"]

  @doc "The tools the page is handed beside the ones its script already knows: none while every feature is off."
  def page_tools, do: if("covered_calls" in features(), do: @covered_calls, else: [])

  defp operations(%{"name" => "prepare_agent_request"} = tool, added) do
    signed = for %{"operation_input_schema" => _, "name" => name} <- added, do: name
    update_in(tool, ["input_schema", "properties", "operation", "enum"], &(&1 ++ signed))
  end

  defp operations(tool, _added), do: tool
end
