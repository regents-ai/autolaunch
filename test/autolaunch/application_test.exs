defmodule Autolaunch.ApplicationTest do
  use ExUnit.Case, async: false

  test "publisher worker is not part of the supervision tree" do
    children = Supervisor.which_children(Autolaunch.Supervisor)

    refute Enum.any?(children, fn {id, _pid, _type, _modules} ->
             id == Autolaunch.Publisher.Worker
           end)
  end
end
