defmodule Autolaunch.Prelaunch do
  @moduledoc "Fail-closed predeployment mode. Disabling it requires an explicit configuration change and restart."

  def read_only?, do: Application.get_env(:autolaunch, :prelaunch_read_only, true) != false
end
