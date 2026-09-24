defmodule Autolaunch.Prelaunch do
  @moduledoc "Fail-closed predeployment mode. Disabling it requires an explicit configuration change and restart."

  @opens_at ~U[2026-09-24 15:00:00Z]

  def read_only?, do: Application.get_env(:autolaunch, :prelaunch_read_only, true) != false

  @doc "When auction creation and bidding open."
  def opens_at, do: @opens_at

  @doc ~S"""
  When Autolaunch opens, as visitors read it after "opens": "Thursday, Sep 24
  at 15:00 UTC" until then, and "soon" once that time has passed while the
  site is still read-only, so a late opening never names a time gone by.
  """
  def opens_at_label do
    if DateTime.compare(DateTime.utc_now(), @opens_at) == :lt,
      do: Calendar.strftime(@opens_at, "%A, %b %-d at %H:%M UTC"),
      else: "soon"
  end
end
