defmodule Autolaunch.Checks.SystemActor do
  use Ash.Policy.SimpleCheck

  alias Autolaunch.Actors.System

  @impl true
  def describe(_opts), do: "actor is the internal system principal"

  @impl true
  def match?(%System{}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
