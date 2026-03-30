defmodule AutolaunchWeb.RegentScenes do
  @moduledoc false

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
          "status" => step_status(step.order, selected_step_index),
          "position" => [step.order * 5 - 12, rem(step.order, 2) * 4, div(step.order, 2) * 4],
          "size" => if(step.order == selected_step_index, do: [3, 3, 2], else: [2, 2, 2]),
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

    base_scene("guide", "Auction guide", "fuse", nodes, conduits)
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
            "label" => selected_agent.name || selected_agent.agent_name || selected_agent.agent_id,
            "status" => "focused",
            "position" => [-8, 1, 0],
            "size" => [2, 4, 2],
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

    base_scene("launch", "Launch control", "fuse", nodes, conduits)
  end

  def auctions(auctions, filters) do
    market_nodes =
      auctions
      |> Enum.take(8)
      |> Enum.with_index()
      |> Enum.map(fn {auction, index} ->
        row = div(index, 4)
        column = rem(index, 4)

        %{
          "id" => "auction:#{auction.id}",
          "kind" => "token",
          "geometry" => "reliquary",
          "sigil" => auction_sigil(auction.status),
          "label" => auction.agent_name,
          "status" => auction_status(auction.status),
          "position" => [column * 6 - 10, row * 6 + 2, rem(index, 2) * 2],
          "size" => [2, 2, 2],
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
        "geometry" => "cube",
        "sigil" => "fuse",
        "label" => "Market lens",
        "status" => "active",
        "position" => [-14, -2, 0],
        "size" => [3, 3, 2],
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

  def auction_detail(nil, _latest_position, _detail_focus), do: base_scene("auction", "Auction detail", "seal", [], [])

  def auction_detail(auction, latest_position, detail_focus) do
    nodes = [
      detail_node("detail:bid", "Bid composer", "fuse", 0, detail_focus),
      detail_node("detail:estimate", "Estimator", "eye", 1, detail_focus),
      detail_node("detail:trust", "Trust state", "seal", 2, detail_focus),
      detail_node("detail:claim", human_position_status(latest_position), "gate", 3, detail_focus),
      %{
        "id" => "detail:auction",
        "kind" => "token",
        "geometry" => "monolith",
        "sigil" => auction_sigil(auction.status),
        "label" => auction.agent_name,
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

    base_scene("auction", "Auction detail", "seal", nodes, conduits)
  end

  defp base_scene(face_id, title, sigil, nodes, conduits) do
    %{
      "app" => "autolaunch",
      "theme" => "autolaunch",
      "activeFace" => face_id,
      "camera" => %{"type" => "oblique", "angle" => 315, "distance" => 24},
      "faces" => [
        %{
          "id" => face_id,
          "title" => title,
          "sigil" => sigil,
          "orientation" => "front",
          "nodes" => nodes,
          "conduits" => conduits
        }
      ]
    }
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
      "status" => status,
      "position" => [offset * 6 - 4, offset * 2, 0],
      "size" => if(step_number == current_step, do: [3, 3, 2], else: [2, 2, 2]),
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

  defp human_position_status(nil), do: "No position"
  defp human_position_status(position), do: Map.get(position, :status, "Position")
end
