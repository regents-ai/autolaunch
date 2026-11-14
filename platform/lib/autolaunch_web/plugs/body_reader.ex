defmodule AutolaunchWeb.Plugs.BodyReader do
  @moduledoc """
  Retains exact bounded bytes only for signed agent routes, the MCP address and
  a profile change.

  A signed body is at most 16 KB, except a draft save, which carries the
  draft's picture: up to 2 MB of it, in base64, beside the same 16 KB, and a
  profile change, at most 8 KB.
  """

  @limit 16_384
  @profile_limit 8192

  # The largest picture a draft takes, 2 MB (2,097,152 bytes, as
  # `Autolaunch.LaunchDraft.ImageValidator` holds it), is 2,796,204 bytes of
  # base64. The figure is written out so the endpoint, which names this module
  # as it compiles, does not come to depend on the picture check.
  @draft_limit @limit + 2_796_204

  def read_body(
        %{method: "PATCH", path_info: ["api", "agent", "v1", "drafts", kind]} = conn,
        opts
      )
      when kind in ["revstake", "memestock"],
      do: Siwa.AgentAuthPlug.read_body(conn, opts, @draft_limit)

  def read_body(%{path_info: ["api", area | _]} = conn, opts)
      when area in ["agent", "agents"],
      do: Siwa.AgentAuthPlug.read_body(conn, opts, @limit)

  def read_body(%{method: "POST", path_info: ["mcp"]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, @limit)

  # A paired agent may change its person's profile with a signed request.
  def read_body(%{method: "PATCH", path_info: ["api", "v1", "profile"]} = conn, opts),
    do: Siwa.AgentAuthPlug.read_body(conn, opts, @profile_limit)

  def read_body(conn, opts), do: RegentIdentity.BodyReader.read_body(conn, opts)
end
