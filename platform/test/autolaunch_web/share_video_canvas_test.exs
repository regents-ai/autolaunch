defmodule AutolaunchWeb.ShareVideoCanvasTest do
  @moduledoc """
  A share video whose encoder stops before it has taken every frame is a
  failed render that says how the encoder ended, so the video's request is
  marked failed and can be asked for again.

  The frames are drawn for real; `ffmpeg` is a script, first on the PATH, that
  takes the start of the first frame and stops with a status of its own.
  """
  use ExUnit.Case, async: false

  alias AutolaunchWeb.ShareVideo.Canvas
  alias Vix.Vips.Operation

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "share-video-canvas-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "ffmpeg")

    File.write!(script, """
    #!/bin/sh
    head -c 1000 > /dev/null
    echo "encoder stopped"
    exit 3
    """)

    File.chmod!(script, 0o755)
    path = System.fetch_env!("PATH")
    System.put_env("PATH", dir <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(dir)
    end)
  end

  test "an encoder that stops early fails the render with how it ended" do
    {:ok, frame} = Operation.black(1080, 1350, bands: 3)

    assert {:error, {:ffmpeg, 3, said}} = Canvas.render(fn _index -> frame end)
    assert said =~ "encoder stopped"
  end
end
