defmodule AutolaunchWeb.RegentScenes do
  @moduledoc false

  alias Regent.SceneSpec

  def guide(steps, selected_step_index) do
    nodes =
      steps
      |> Enum.map(fn step ->
        %{
          "id" => "guide:step:#{step.order}",
          "kind" => "action",
          "geometry" => "cube",
          "sigil" => guide_sigil(step.order),
          "label" => step.eyebrow,
          "actionLabel" => "Open guide step",
          "intent" => "scene_action",
          "groupRole" => "landmark",
          "historyKey" => "autolaunch:guide:overview",
          "status" => step_status(step.order, selected_step_index),
          "position" => [step.order * 5 - 12, rem(step.order, 2) * 4, div(step.order, 2) * 4],
          "size" => if(step.order == selected_step_index, do: [3, 3, 2], else: [2, 2, 1]),
          "scale" =>
            if(step.order == selected_step_index, do: [0.96, 1, 0.96], else: [0.74, 0.62, 0.74]),
          "scaleOrigin" => [0.5, 1, 0.5],
          "meta" => %{"stepIndex" => step.order}
        }
      end)

    conduits =
      if length(steps) < 2 do
        []
      else
        Enum.map(0..(length(steps) - 2), fn index ->
          %{
            "id" => "guide:edge:#{index}",
            "from" => "guide:step:#{index}",
            "to" => "guide:step:#{index + 1}",
            "kind" => "launch_phase",
            "state" => if(index < selected_step_index, do: "flowing", else: "visible"),
            "shape" => "rounded",
            "radius" => 0.55
          }
        end)
      end

    base_scene("guide", "Auction guide", "fuse", nodes, conduits,
      active_camera_preset: if(selected_step_index > 0, do: "node_focus", else: "overview"),
      camera_target_id:
        if(selected_step_index > 0, do: "guide:step:#{selected_step_index}", else: nil)
    )
  end

  def launch(assigns) do
    selected_agent = Map.get(assigns, :selected_agent)
    current_job = Map.get(assigns, :current_job)
    current_step = Map.get(assigns, :step, 1)
    job_status = get_in(current_job || %{}, [:job, :status])

    step_nodes = [
      launch_step_node("launch:step:1", "Choose agent", "gate", 0, current_step, 1),
      launch_step_node("launch:step:2", "Set terms", "seed", 1, current_step, 2),
      launch_step_node("launch:step:3", "Review plan", "seal", 2, current_step, 3),
      launch_step_node("launch:step:4", "Queue launch", "fuse", 3, current_step, 4, job_status)
    ]

    nodes =
      if selected_agent do
        [
          %{
            "id" => "launch:agent",
            "kind" => "agent",
            "geometry" => "monolith",
            "sigil" => "gate",
            "label" =>
              selected_agent.name || selected_agent.agent_name || selected_agent.agent_id,
            "actionLabel" => "Selected launch agent",
            "intent" => "status_only",
            "groupRole" => "landmark",
            "status" => "focused",
            "position" => [-8, 1, 0],
            "size" => [2, 3, 2],
            "scale" => [0.82, 0.92, 0.82],
            "scaleOrigin" => [0.5, 1, 0.5],
            "meta" => %{"role" => "agent"}
          }
          | step_nodes
        ]
      else
        step_nodes
      end

    conduits =
      1..3
      |> Enum.map(fn index ->
        %{
          "id" => "launch:edge:#{index}",
          "from" => "launch:step:#{index}",
          "to" => "launch:step:#{index + 1}",
          "kind" => "launch_phase",
          "state" => if(index < current_step, do: "flowing", else: "visible"),
          "shape" => "rounded",
          "radius" => 0.55
        }
      end)

    base_scene("launch", "Launch control", "fuse", nodes, conduits,
      active_camera_preset: launch_camera_preset(current_step, current_job),
      camera_target_id: launch_camera_target(current_step, current_job)
    )
  end

  def auctions(auctions, filters) do
    market_nodes =
      auctions
      |> Enum.take(8)
      |> Enum.with_index()
      |> Enum.map(fn {auction, index} ->
        row = div(index, 4)
        column = rem(index, 4)
        height = auction_cell_height(auction.status, row)

        %{
          "id" => "auction:#{auction.id}",
          "kind" => "token",
          "geometry" => "reliquary",
          "sigil" => auction_sigil(auction.status),
          "label" => auction.agent_name,
          "actionLabel" => "Open auction detail",
          "intent" => "navigate",
          "groupRole" => "landmark",
          "historyKey" => "autolaunch:auctions:overview",
          "status" => auction_status(auction.status),
          "position" => [column * 6 - 10, row * 7 + 1, row * 2 + rem(index, 2)],
          "size" => [3, height, 2],
          "scale" => auction_cell_scale(auction.status, row),
          "scaleOrigin" => [0.5, 1, 0.5],
          "meta" => %{
            "auctionId" => auction.id,
            "status" => auction.status
          }
        }
      end)

    nodes = [
      %{
        "id" => "auction:market",
        "kind" => "memory",
        "geometry" => "monolith",
        "sigil" => "fuse",
        "label" => "Market lens",
        "actionLabel" => "Market overview",
        "intent" => "status_only",
        "groupRole" => "strip",
        "status" => "active",
        "position" => [-15, -1, 0],
        "size" => [2, 4, 2],
        "scale" => [0.8, 0.92, 0.8],
        "scaleOrigin" => [0.5, 1, 0.5],
        "meta" => %{
          "sort" => Map.get(filters, "sort"),
          "status" => Map.get(filters, "status"),
          "chain" => Map.get(filters, "chain")
        }
      }
      | market_nodes
    ]

    conduits =
      market_nodes
      |> Enum.map(fn node ->
        %{
          "id" => "auction:edge:#{node["id"]}",
          "from" => "auction:market",
          "to" => node["id"],
          "kind" => "launch_phase",
          "state" => "visible",
          "shape" => "rounded",
          "radius" => 0.45
        }
      end)

    base_scene("auctions", "Auction market", "fuse", nodes, conduits)
  end

  def auction_detail(nil, _latest_position, _detail_focus),
    do: base_scene("auction", "Auction detail", "seal", [], [])

  def auction_detail(auction, latest_position, detail_focus) do
    nodes = [
      detail_node("detail:bid", "Bid composer", "fuse", 0, detail_focus),
      detail_node("detail:estimate", "Estimator", "eye", 1, detail_focus),
      detail_node("detail:trust", "Trust state", "seal", 2, detail_focus),
      detail_node(
        "detail:claim",
        human_position_status(latest_position),
        "gate",
        3,
        detail_focus
      ),
      %{
        "id" => "detail:auction",
        "kind" => "token",
        "geometry" => "monolith",
        "sigil" => auction_sigil(auction.status),
        "label" => auction.agent_name,
        "actionLabel" => "Auction overview",
        "intent" => "status_only",
        "groupRole" => "landmark",
        "status" => "focused",
        "position" => [-10, 2, 0],
        "size" => [2, 4, 2],
        "meta" => %{"role" => "auction"}
      }
    ]

    conduits =
      ["detail:bid", "detail:estimate", "detail:trust", "detail:claim"]
      |> Enum.map(fn node_id ->
        %{
          "id" => "detail:edge:#{node_id}",
          "from" => "detail:auction",
          "to" => node_id,
          "kind" => "launch_phase",
          "state" => if(node_id == detail_focus, do: "flowing", else: "visible"),
          "shape" => "rounded",
          "radius" => 0.5
        }
      end)

    base_scene("auction", "Auction detail", "seal", nodes, conduits,
      active_camera_preset: if(detail_focus == "detail:bid", do: "overview", else: "node_focus"),
      camera_target_id: if(detail_focus == "detail:bid", do: nil, else: detail_focus)
    )
  end

  defp base_scene(face_id, title, sigil, nodes, conduits, opts \\ []) do
    {commands, markers} = assemble_face(nodes, conduits)

    face =
      SceneSpec.face(face_id, title, sigil, commands, markers, orientation: "front")

    SceneSpec.scene("autolaunch", "autolaunch", face_id, face,
      distance: Keyword.get(opts, :distance, 24),
      camera_presets: market_camera_presets(),
      active_camera_preset: Keyword.get(opts, :active_camera_preset, "overview"),
      camera_target_id: Keyword.get(opts, :camera_target_id)
    )
  end

  defp launch_step_node(id, label, sigil, offset, current_step, step_number, job_status \\ nil) do
    status =
      cond do
        step_number == current_step and job_status in ["running", "queued"] -> "active"
        step_number == current_step -> "focused"
        step_number < current_step -> "complete"
        true -> "available"
      end

    %{
      "id" => id,
      "kind" => "action",
      "geometry" => "cube",
      "sigil" => sigil,
      "label" => label,
      "actionLabel" => "Open launch step",
      "intent" => "scene_action",
      "groupRole" => "landmark",
      "historyKey" => "autolaunch:launch:step",
      "status" => status,
      "position" => [offset * 6 - 4, offset * 2, 0],
      "size" => if(step_number == current_step, do: [3, 3, 2], else: [2, 2, 1]),
      "scale" => if(step_number == current_step, do: [0.96, 1, 0.96], else: [0.74, 0.62, 0.74]),
      "scaleOrigin" => [0.5, 1, 0.5],
      "meta" => %{"step" => step_number}
    }
  end

  defp detail_node(id, label, sigil, offset, detail_focus) do
    %{
      "id" => id,
      "kind" => "state",
      "geometry" => "cube",
      "sigil" => sigil,
      "label" => label,
      "actionLabel" => "Open detail panel",
      "intent" => "scene_action",
      "groupRole" => "chamber-entry",
      "historyKey" => "autolaunch:auction:detail",
      "status" => if(id == detail_focus, do: "focused", else: "available"),
      "position" => [offset * 5 - 2, offset * 2, 0],
      "size" => if(id == detail_focus, do: [3, 3, 2], else: [2, 2, 2]),
      "meta" => %{"panel" => id}
    }
  end

  defp step_status(order, selected_step_index) when order < selected_step_index, do: "complete"
  defp step_status(order, selected_step_index) when order == selected_step_index, do: "focused"
  defp step_status(_order, _selected_step_index), do: "available"

  defp guide_sigil(order) when order in [0, 1], do: "gate"
  defp guide_sigil(order) when order in [2, 3], do: "fuse"
  defp guide_sigil(order) when order in [4, 5], do: "seal"
  defp guide_sigil(_order), do: "fuse"

  defp auction_sigil(status) when status in ["active", "ending-soon"], do: "fuse"
  defp auction_sigil(status) when status in ["claimable", "pending-claim"], do: "seal"
  defp auction_sigil(status) when status in ["borderline", "inactive"], do: "wedge"
  defp auction_sigil(_status), do: "gate"

  defp auction_status(status) when status in ["active", "ending-soon"], do: "active"
  defp auction_status(status) when status in ["claimable", "pending-claim"], do: "complete"
  defp auction_status(status) when status in ["inactive", "borderline", "expired"], do: "invalid"
  defp auction_status(_status), do: "available"

  defp auction_cell_height(status, row) when status in ["active", "ending-soon"], do: 2 + row
  defp auction_cell_height(status, _row) when status in ["claimable", "pending-claim"], do: 1
  defp auction_cell_height(_status, _row), do: 1

  defp auction_cell_scale(status, row) when status in ["active", "ending-soon"],
    do: [0.82, 0.88 - row * 0.04, 0.82]

  defp auction_cell_scale(status, _row) when status in ["claimable", "pending-claim"],
    do: [0.78, 0.62, 0.78]

  defp auction_cell_scale(status, _row) when status in ["inactive", "borderline", "expired"],
    do: [0.72, 0.5, 0.72]

  defp auction_cell_scale(_status, _row), do: [0.76, 0.58, 0.76]

  defp market_camera_presets do
    %{
      "overview" => %{
        "type" => "oblique",
        "angle" => 315,
        "distance" => 24,
        "padding" => 42,
        "zoom" => 1.0
      },
      "focus_travel" => %{
        "type" => "oblique",
        "angle" => 307,
        "distance" => 20,
        "padding" => 24,
        "zoom" => 2.15
      },
      "node_focus" => %{
        "type" => "oblique",
        "angle" => 300,
        "distance" => 17,
        "padding" => 20,
        "zoom" => 2.8
      }
    }
  end

  defp launch_camera_preset(current_step, current_job) do
    cond do
      current_job -> "overview"
      current_step > 1 -> "node_focus"
      true -> "overview"
    end
  end

  defp launch_camera_target(current_step, current_job) do
    if current_job || current_step <= 1, do: nil, else: "launch:step:#{min(current_step, 4)}"
  end

  defp human_position_status(nil), do: "No position"
  defp human_position_status(position), do: Map.get(position, :status, "Position")

  defp assemble_face(nodes, conduits) do
    nodes_by_id = Map.new(nodes, &{&1["id"], &1})
    entries = Enum.map(nodes, &node_entry/1)

    commands =
      Enum.flat_map(entries, & &1.commands) ++
        Enum.flat_map(conduits, &conduit_commands(&1, nodes_by_id))

    markers = Enum.map(entries, & &1.marker)
    {commands, markers}
  end

  defp node_entry(node) do
    node_id = node["id"]
    status = node["status"] || "available"
    position = node["position"] || [0, 0, 0]
    size = node["size"] || [1, 1, 1]
    geometry = node["geometry"] || "cube"
    target_id = node_id
    hover_cycle = Map.get(node, "hoverCycle")
    meta = Map.get(node, "meta", %{})
    command_id = node["commandId"] || "#{node_id}:body"
    custom_commands = Map.get(node, "commands")

    marker =
      SceneSpec.marker(target_id,
        label: node["label"] || node_id,
        action_label: node["actionLabel"],
        sigil: node["sigil"],
        kind: node["kind"],
        status: status,
        intent: node["intent"] || "scene_action",
        back_target_id: node["backTargetId"],
        history_key: node["historyKey"],
        group_role: node["groupRole"],
        click_tone: node["clickTone"],
        meta: meta,
        command_id: command_id
      )

    intent_style = SceneSpec.intent_style(SceneSpec.node_style(status), node["intent"])

    commands =
      if is_list(custom_commands) do
        custom_commands
      else
        case geometry do
          "socket" ->
            [
              SceneSpec.add_sphere(
                command_id,
                SceneSpec.sphere_center(position, size),
                SceneSpec.sphere_radius(size),
                style: intent_style,
                hover_cycle: hover_cycle,
                target_id: target_id,
                scale: node["scale"] || SceneSpec.socket_scale(size, status),
                scale_origin: node["scaleOrigin"] || [0.5, 1, 0.5]
              )
            ]

          "carved_cube" ->
            [
              SceneSpec.add_box(
                command_id,
                position,
                size,
                style: intent_style,
                hover_cycle: hover_cycle,
                target_id: target_id
              ),
              SceneSpec.remove_box(
                "#{node_id}:carve",
                SceneSpec.inset_position(position),
                SceneSpec.inset_size(size),
                style: SceneSpec.carved_wall_style(status),
                target_id: target_id
              )
            ]

          "ghost" ->
            [
              SceneSpec.add_box(
                command_id,
                position,
                size,
                style: SceneSpec.ghost_style(),
                opaque: false,
                hover_cycle: hover_cycle,
                target_id: target_id
              )
            ]

          "reliquary" ->
            [
              SceneSpec.add_box(
                command_id,
                position,
                size,
                style: intent_style,
                hover_cycle: hover_cycle,
                target_id: target_id,
                scale: node["scale"] || [0.88, 0.92, 0.88],
                scale_origin: node["scaleOrigin"] || [0.5, 1, 0.5]
              )
            ]

          "monolith" ->
            [
              SceneSpec.add_box(
                command_id,
                position,
                size,
                style: intent_style,
                hover_cycle: hover_cycle,
                target_id: target_id,
                scale: node["scale"] || [0.9, 1, 0.9],
                scale_origin: node["scaleOrigin"] || [0.5, 1, 0.5]
              )
            ]

          _ ->
            [
              SceneSpec.add_box(
                command_id,
                position,
                size,
                style: intent_style,
                opaque: Map.get(node, "opaque"),
                hover_cycle: hover_cycle,
                target_id: target_id,
                scale: SceneSpec.default_scale(node, status),
                scale_origin: SceneSpec.default_scale_origin(node, status)
              )
            ]
        end
      end

    %{commands: commands, marker: marker}
  end

  defp conduit_commands(conduit, nodes_by_id) do
    custom_commands = Map.get(conduit, "commands")

    cond do
      is_list(custom_commands) ->
        custom_commands

      true ->
        with from_node when is_map(from_node) <- Map.get(nodes_by_id, conduit["from"]),
             to_node when is_map(to_node) <- Map.get(nodes_by_id, conduit["to"]) do
          base =
            SceneSpec.add_line(
              "#{conduit["id"]}:line",
              SceneSpec.anchor(Map.fetch!(from_node, "position"), Map.fetch!(from_node, "size")),
              SceneSpec.anchor(Map.fetch!(to_node, "position"), Map.fetch!(to_node, "size")),
              radius: conduit["radius"] || 0.75,
              shape: conduit["shape"] || "rounded",
              style: SceneSpec.conduit_style(conduit["state"] || "visible"),
              hover_cycle: conduit["hoverCycle"]
            )

          waypoints =
            conduit
            |> Map.get("waypoints", [])
            |> Enum.with_index()
            |> Enum.map(fn {point, index} ->
              SceneSpec.add_sphere(
                "#{conduit["id"]}:waypoint:#{index}",
                point,
                0.6,
                style: SceneSpec.conduit_style(conduit["state"] || "visible"),
                hover_cycle: conduit["hoverCycle"]
              )
            end)

          [base | waypoints]
        else
          _ -> []
        end
    end
  end
end
