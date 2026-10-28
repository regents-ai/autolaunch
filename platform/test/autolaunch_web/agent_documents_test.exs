defmodule AutolaunchWeb.AgentDocumentsTest do
  @moduledoc """
  The agent documents agree with each other and with the deployment: every
  public document names the one regents-cli release they were checked against,
  the signed agent guide states the prelaunch gate as it stands, and the short
  index leads to the whole guide and the Markdown sitemap.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias AutolaunchWeb.PublicDocuments

  @documents ~w(/llms.txt /llms-full.txt /agents.md /skill.md /sitemap.md)
  @pages ~w(/ /docs /about /contact /privacy /terms)

  test "every public document names only the one regents-cli release", %{conn: conn} do
    bodies =
      Enum.map(@documents, &(conn |> get(&1) |> response(200))) ++
        Enum.map(
          @pages,
          &(conn |> put_req_header("accept", "text/markdown") |> get(&1) |> response(200))
        )

    # A dotted release number, not a part of a longer one such as an IP address.
    versions =
      bodies
      |> Enum.flat_map(&Regex.scan(~r/(?<![\d.])\d+\.\d+\.\d+(?!\.?\d)/, &1))
      |> List.flatten()

    assert versions != []
    assert Enum.uniq(versions) == [PublicDocuments.regents_cli_version()]
    refute Enum.any?(bodies, &(&1 =~ "{{"))
  end

  # PAIRING_MESSAGE_STEPS_ARE_WHERE_IT_SAYS: the message a person pastes to their
  # agent sent it to "Pair with a person's account" steps at /llms.txt, which had
  # no such steps (found by the agent journeys, 27 Oct 2026).
  test "PAIRING_MESSAGE_STEPS_ARE_WHERE_IT_SAYS: the steps the pairing message names are in the document it names",
       %{conn: conn} do
    message = RegentAgents.PairingMessage.text("code", AutolaunchWeb.Endpoint.url(), :codex)
    [_line, title, address] = Regex.run(~r/Follow the "([^"]+)" steps at (\S+)/, message)

    [_before, steps] =
      conn |> get(URI.parse(address).path) |> response(200) |> String.split("\n## #{title}\n")

    [steps | _rest] = String.split(steps, "\n## ")

    for command <- [
          "auth login --site autolaunch",
          "agents whoami",
          "agents pair",
          "agents status"
        ],
        do: assert(steps =~ "regents #{command}" or steps =~ "regents autolaunch #{command}")
  end

  test "the signed agent guide states the prelaunch gate as this deployment has it", %{conn: conn} do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)

    Application.put_env(:autolaunch, :prelaunch_read_only, true)
    assert conn |> get("/agents.md") |> response(200) =~ "Read-only mode is on right now"

    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    assert build_conn() |> get("/agents.md") |> response(200) =~ "Read-only mode is off right now"
  end

  test "the short index leads to the whole guide, which carries every tool", %{conn: conn} do
    index = conn |> get("/llms.txt") |> response(200)
    full = conn |> get("/llms-full.txt") |> response(200)
    sitemap = conn |> get("/sitemap.md") |> response(200)

    assert index =~ "/llms-full.txt" and index =~ "/sitemap.md"
    assert byte_size(index) * 3 < byte_size(full)

    for %{"name" => name} <- PublicDocuments.capabilities()["tools"],
        do: assert(full =~ "`#{name}`")

    assert sitemap =~ "/llms.txt" and sitemap =~ "/llms-full.txt"
  end
end
