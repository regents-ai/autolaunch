defmodule Autolaunch.Earn.Checks.Offered do
  @moduledoc """
  Holds while the site offers Earn (`AUTOLAUNCH_EARN`, `Autolaunch.Earn.Catalog`).
  Off, the operations every agent surface runs are refused, so the hosted MCP
  server neither lists nor runs them, as the routes and browser tools are not
  there either.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the site offers Earn"

  @impl true
  def match?(_actor, _context, _opts), do: Autolaunch.Earn.Catalog.enabled?()
end
