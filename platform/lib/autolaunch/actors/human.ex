defmodule Autolaunch.Actors.Human do
  @moduledoc false
  @enforce_keys [:human_account_id]
  defstruct [:human_account_id, role: :human]
end
