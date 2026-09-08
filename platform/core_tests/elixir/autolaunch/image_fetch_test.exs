defmodule Autolaunch.ImageFetchTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.ImageFetch
  alias Autolaunch.LaunchDraft.ImageValidator

  # Req 0.6.2 run_plug calls into: once with conn.resp_body already complete, so
  # plug: cannot stream chunks. This adapter feeds into: itself and stops.
  test "abandons a streamed body once the running total exceeds the cap" do
    max = ImageValidator.maximum_bytes()
    chunk = :binary.copy("x", div(max, 4) + 1)
    delivered = :counters.new(1, [])

    adapter = fn request ->
      response = Req.Response.new(status: 200, headers: [{"content-type", "image/png"}])

      Enum.reduce_while(1..8, {request, response}, fn _i, {req, resp} ->
        :counters.add(delivered, 1, 1)
        request.into.({:data, chunk}, {req, resp})
      end)
    end

    assert {:error, :image_too_large} =
             ImageFetch.fetch("http://8.8.8.8/stream.png", adapter: adapter)

    assert :counters.get(delivered, 1) < 8
    assert :counters.get(delivered, 1) >= 4
  end

  test "refuses loopback and private literals before any request" do
    plug = fn _conn -> flunk("request was made") end

    assert {:error, :private_address} =
             ImageFetch.fetch("http://127.0.0.1/x.png", plug: plug)

    assert {:error, :private_address} =
             ImageFetch.fetch("http://10.0.0.5/x.png", plug: plug)
  end
end
