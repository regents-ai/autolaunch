defmodule AutolaunchWeb.Capabilities do
  @moduledoc """
  The surfaces each agent operation is on, from `priv/capabilities.json`: one row
  per browser tool (`priv/tool_manifest.json`, and the covered-call,
  Isolated Exposure to After-hours Stocks, Earn, agent bid, agent Robinhood
  bid, agent launch, agent finish and agent staking page tools), and one per
  tool only the hosted MCP server has, such as a connected app's identity
  tools. Each row names its four
  surfaces, `webmcp`, `hosted_mcp`, `http` and `cli`, each `true` or the reason
  it is left out, who may run it, the switch it follows and, when it is on the
  hosted MCP server, that tool's name (`hosted_tool`).

  These are checked against each other when this module compiles: every browser
  tool has one row, in the manifest's order; `webmcp` and `http` are true exactly
  for a browser tool, whose `requires` gives the row's authority and whose file
  gives its switch; `hosted_mcp` is true exactly for the rows whose
  `hosted_tool` is one of the AshAi tools the site's domains declare, every one
  of them named once and taking its browser tool's input, or, for a tool only
  the hosted server has, named after its row, run by a connected app and on no
  other surface. The hosted server serves those tools
  (`hosted_tools/0`); AshAi lists each to a caller only as its action's policies
  allow.

  The guides' Agent access table, their words on the hosted MCP server and the
  server's own instructions are made from the rows offered now
  (`AutolaunchWeb.PublicDocuments`), so they name what each surface serves.
  """

  paths = [
    source: Application.app_dir(:autolaunch, "priv/capabilities.json"),
    manifest: Application.app_dir(:autolaunch, "priv/tool_manifest.json"),
    covered_calls: Application.app_dir(:autolaunch, "priv/covered_calls_tools.json"),
    exposure: Application.app_dir(:autolaunch, "priv/exposure_tools.json"),
    earn: Application.app_dir(:autolaunch, "priv/earn_tools.json"),
    agent_bids: Application.app_dir(:autolaunch, "priv/agent_bids_tools.json"),
    agent_robinhood_bids:
      Application.app_dir(:autolaunch, "priv/agent_robinhood_bids_tools.json"),
    agent_launches: Application.app_dir(:autolaunch, "priv/agent_launches_tools.json"),
    agent_finish: Application.app_dir(:autolaunch, "priv/agent_finish_tools.json"),
    agent_staking: Application.app_dir(:autolaunch, "priv/agent_stake_tools.json")
  ]

  for {_name, path} <- paths, do: @external_resource(path)
  files = Map.new(paths, fn {name, path} -> {name, path |> File.read!() |> Jason.decode!()} end)

  # Each browser tool, with the switch it follows: none for the site's own.
  browser =
    for {file, switch} <- [
          manifest: nil,
          covered_calls: "covered_calls",
          exposure: "exposure",
          earn: "earn",
          agent_bids: "agent_bids",
          agent_robinhood_bids: "agent_robinhood_bids",
          agent_launches: "agent_launches",
          agent_finish: "agent_finish",
          agent_staking: "agent_staking"
        ],
        tool <- files[file]["tools"],
        do: Map.put(tool, "switch", switch)

  authorities = %{
    "none" => "public",
    "siwa" => "signed_agent",
    "siwa_and_pairing" => "paired_agent"
  }

  # The tools the site's domains hand AshAi for hosted MCP, by name, with the
  # input AshAi asks for and the title it lists.
  hosted =
    for domain <- Application.compile_env!(:autolaunch, :ash_domains),
        tool <- AshAi.Info.tools(domain),
        into: %{} do
      action = Ash.Resource.Info.action(tool.resource, tool.action)

      schema =
        AshAi.Tool.Schema.for_action(domain, tool.resource, action, nil, [], strict?: false)

      {Atom.to_string(tool.name), %{input: schema["properties"]["input"], title: tool.title}}
    end

  # An input's shape for comparing two schemas: each field's type and choices, and
  # which fields are required. Words and lengths are left out.
  shape = fn schema ->
    {Map.new(schema["properties"] || %{}, fn {name, field} ->
       {name, Map.take(field, ~w(type enum format))}
     end), MapSet.new(schema["required"] || [])}
  end

  surface_names = ~w(cli hosted_mcp http webmcp)
  rows = files.source["operations"]
  {browser_rows, hosted_only_rows} = Enum.split(rows, length(browser))

  unless Enum.map(browser_rows, & &1["operation"]) == Enum.map(browser, & &1["name"]),
    do: raise("priv/capabilities.json must list every browser tool once, in the manifests' order")

  for {row, tool} <- Enum.zip(browser_rows, browser) do
    surfaces = row["surfaces"]
    name = tool["name"]

    problem =
      cond do
        Map.keys(surfaces) |> Enum.sort() != surface_names or
            not Enum.all?(Map.values(surfaces), &(&1 == true or (is_binary(&1) and &1 != ""))) ->
          "a surface left out with no reason"

        surfaces["webmcp"] != true or surfaces["http"] != true ->
          "a browser tool and its route not marked true"

        row["authority"] != authorities[tool["requires"]] ->
          "an authority that differs from its browser tool's"

        row["switch"] != tool["switch"] ->
          "a switch that differs from its browser tool's file"

        surfaces["hosted_mcp"] == true != Map.has_key?(hosted, row["hosted_tool"]) ->
          "hosted_mcp that differs from its hosted_tool being an AshAi tool"

        Map.has_key?(hosted, row["hosted_tool"]) and
            shape.(hosted[row["hosted_tool"]].input) != shape.(tool["input_schema"]) ->
          "hosted input that differs from the browser tool's input"

        true ->
          nil
      end

    if problem, do: raise("#{name} in priv/capabilities.json has #{problem}")
  end

  for row <- hosted_only_rows do
    surfaces = row["surfaces"]

    unless row["hosted_tool"] == row["operation"] and Map.has_key?(hosted, row["operation"]) and
             surfaces["hosted_mcp"] == true and
             row["authority"] == "connected_app" and row["switch"] == "connected_apps" and
             Map.keys(surfaces) |> Enum.sort() == surface_names and
             Enum.all?(~w(webmcp http cli), &(is_binary(surfaces[&1]) and surfaces[&1] != "")),
           do:
             raise(
               "#{row["operation"]} in priv/capabilities.json must be an AshAi tool only the " <>
                 "hosted MCP server has, run by a connected app, with a reason for every other surface"
             )
  end

  @hosted for %{"surfaces" => %{"hosted_mcp" => true}, "hosted_tool" => name} <- rows,
              do: String.to_atom(name)

  unless Enum.sort(Enum.map(@hosted, &Atom.to_string/1)) == Enum.sort(Map.keys(hosted)),
    do: raise("priv/capabilities.json must name every AshAi tool once as a hosted_tool")

  # Each row with the title its tool shows: its browser tool's, with that tool's
  # route, or, for a tool only the hosted server has, that tool's.
  @operations Enum.zip_with(browser_rows, browser, &Map.merge(&1, Map.take(&2, ~w(title route)))) ++
                Enum.map(hosted_only_rows, &Map.put(&1, "title", hosted[&1["operation"]].title))

  @doc "The hosted MCP server's tools, by the name AshAi gives each."
  @spec hosted_tools() :: [atom()]
  def hosted_tools, do: @hosted

  @doc """
  Every operation's row, as `priv/capabilities.json` gives it, with its tool's
  `title` and, for a browser tool, its `route`, such as `GET /api/v1/auctions`.
  """
  @spec operations() :: [map()]
  def operations, do: @operations

  @doc "The operations offered while the switches named in `on` are on: the site's own and each one whose switch is among them."
  @spec offered([String.t()]) :: [map()]
  def offered(on), do: Enum.filter(@operations, &(&1["switch"] in [nil | on]))
end
