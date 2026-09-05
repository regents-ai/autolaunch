defmodule Autolaunch.Accounts.Checks.HumanActor do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  alias Autolaunch.Actors.Human

  @impl true
  def describe(_opts), do: "actor is the browser human principal"

  @impl true
  def match?(%Human{human_account_id: id}, _context, _opts) when is_integer(id), do: true
  def match?(_actor, _context, _opts), do: false
end
