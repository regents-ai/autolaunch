defmodule Autolaunch.Actors.Human do
  @moduledoc false
  @enforce_keys [:human_account_id]
  defstruct [:human_account_id, role: :human]

  @type t :: %__MODULE__{human_account_id: integer(), role: :human}
end
