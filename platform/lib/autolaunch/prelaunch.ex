defmodule Autolaunch.Prelaunch do
  @moduledoc "Fail-closed predeployment mode. Disabling it requires an explicit configuration change and restart."

  @opens_at ~U[2026-09-24 15:00:00Z]

  def read_only?, do: Application.get_env(:autolaunch, :prelaunch_read_only, true) != false

  @doc "When auction creation and bidding open."
  def opens_at, do: @opens_at

  @doc ~S|The opening time as visitors read it: "Thursday, Sep 24 at 15:00 UTC".|
  def opens_at_label, do: Calendar.strftime(@opens_at, "%A, %b %-d at %H:%M UTC")
end
