defmodule Autolaunch.ImageFetchTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.ImageFetch
  alias Autolaunch.LaunchDraft.ImageValidator
  alias Autolaunch.LaunchDraftImageStorage

  test "fetches a public PNG" do
    assert {:ok, {bytes, "image/png"}} =
             ImageFetch.fetch("http://8.8.8.8/token.png", plug: png_plug())

    assert bytes == png()
  end

  test "follows one redirect" do
    plug = fn conn ->
      case conn.request_path do
        "/from.png" ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://8.8.8.8/to.png")
          |> Plug.Conn.send_resp(302, "")

        "/to.png" ->
          png_resp(conn)
      end
    end

    assert {:ok, {bytes, "image/png"}} =
             ImageFetch.fetch("http://8.8.8.8/from.png", plug: plug)

    assert bytes == png()
  end

  test "refuses a fourth redirect" do
    plug = fn conn ->
      next =
        case conn.request_path do
          "/a.png" -> "/b.png"
          "/b.png" -> "/c.png"
          "/c.png" -> "/d.png"
          "/d.png" -> "/e.png"
        end

      conn
      |> Plug.Conn.put_resp_header("location", "http://8.8.8.8#{next}")
      |> Plug.Conn.send_resp(302, "")
    end

    assert {:error, :too_many_redirects} =
             ImageFetch.fetch("http://8.8.8.8/a.png", plug: plug)
  end

  test "refuses a non-image body" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, "not-an-image")
    end

    assert {:error, :invalid_image} = ImageFetch.fetch("http://8.8.8.8/x.png", plug: plug)
  end

  test "refuses an oversize body" do
    body = :binary.copy("x", ImageValidator.maximum_bytes() + 1)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    assert {:error, :image_too_large} = ImageFetch.fetch("http://8.8.8.8/big.png", plug: plug)
  end

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

  test "store_fetched attaches the image and public_url matches the launch envelope" do
    previous = Application.get_env(:autolaunch, ImageFetch, [])
    Application.put_env(:autolaunch, ImageFetch, plug: png_plug())
    on_exit(fn -> restore_image_fetch_env(previous) end)

    actor = actor!("fetched-image")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, stored} =
             LaunchDraftImageStorage.store_fetched(draft, "http://8.8.8.8/token.png", actor)

    assert stored.image.content_type == "image/png"
    assert stored.image.original_filename == "token.png"
    assert stored.draft.image == LaunchDraftImageStorage.public_url(stored.image)

    assert stored.draft.image ==
             AutolaunchWeb.Endpoint.url() <> "/images/#{stored.image.id}/#{stored.image.digest}"
  end

  defp png_plug do
    fn conn -> png_resp(conn) end
  end

  defp png_resp(conn) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "image/png")
    |> Plug.Conn.send_resp(200, png())
  end

  defp png, do: File.read!("test/support/fixtures/launch-draft.png")

  defp actor!(suffix) do
    account =
      Accounts.register_verified!(
        "did:privy:image-fetch:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
        nil,
        [],
        actor: %System{}
      )

    %Human{human_account_id: account.id}
  end

  defp restore_image_fetch_env([]), do: Application.delete_env(:autolaunch, ImageFetch)

  defp restore_image_fetch_env(previous),
    do: Application.put_env(:autolaunch, ImageFetch, previous)
end
