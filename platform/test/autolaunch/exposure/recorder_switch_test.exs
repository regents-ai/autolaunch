defmodule Autolaunch.Exposure.RecorderSwitchTest do
  @moduledoc """
  With `AUTOLAUNCH_EXPOSURE_RECORDER_ON` unset the site starts without the
  recorder's wallet and its queue stays paused, so none of its jobs run.
  """
  use ExUnit.Case, async: false

  @config Path.expand("../../../config/config.exs", __DIR__)
  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @switch "AUTOLAUNCH_EXPOSURE_RECORDER_ON"

  setup do
    saved = System.get_env(@switch)
    System.delete_env(@switch)
    on_exit(fn -> if saved, do: System.put_env(@switch, saved) end)
  end

  test "with the switch unset the recorder has no wallet and its queue stays paused" do
    shipped = Config.Reader.read!(@config, env: :prod)
    assert shipped[:autolaunch][Oban][:queues][:exposure_recording] == [limit: 1, paused: true]

    runtime = Config.Reader.read!(@runtime, env: :test, target: :host)
    refute Keyword.has_key?(runtime[:autolaunch], :exposure_recorder_key)
    refute runtime[:autolaunch][Oban][:queues][:exposure_recording]
  end
end
