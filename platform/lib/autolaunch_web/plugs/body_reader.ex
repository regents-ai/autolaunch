defmodule AutolaunchWeb.Plugs.BodyReader do
  @moduledoc "Retains exact bounded bytes only for signed agent routes and the MCP address."
  def read_body(%{path_info: ["api", area | _]} = conn, opts)
      when area in ["agent", "agents"],
      do: Siwa.AgentAuthPlug.read_body(conn, opts, 16_384)

  def read_body(%{method: "POST", path_info: ["mcp"]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, 16_384)

  def read_body(conn, opts), do: RegentIdentity.BodyReader.read_body(conn, opts)
end
