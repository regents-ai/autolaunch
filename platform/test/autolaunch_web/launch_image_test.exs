defmodule AutolaunchWeb.LaunchImageTest do
  @moduledoc """
  A launch picture's addresses: the stored bytes at `/images/<id>/<digest>`
  and a sized copy at `/images/<id>/<digest>/<width>.webp`. Only an exact
  address of a stored picture reaches the one resizer, and every picture
  answer says a page opened from it may do nothing.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.{CallRecord, LaunchDraftImageStorage}
  alias Autolaunch.StoredImage.Resizer

  setup do
    account =
      Accounts.register_verified!(
        "did:privy:autolaunch-picture:#{Elixir.System.unique_integer([:positive])}",
        nil,
        [],
        actor: %System{}
      )

    actor = %Human{human_account_id: account.id}
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)
    bytes = File.read!("test/support/fixtures/launch-draft.jpg")

    {:ok, %{image: image}} =
      LaunchDraftImageStorage.store_and_attach(draft, bytes, "image/jpeg", "launch.jpg", actor)

    %{picture: "/images/#{image.id}/#{image.digest}", id: image.id, digest: image.digest}
  end

  test "PICTURE_MISSES: each miss on a sized picture's address is refused and never reaches the resizer",
       %{conn: conn, picture: picture, id: id, digest: digest} do
    misses = [
      # a width pages never ask for
      picture <> "/100.webp",
      # a type other than WebP
      picture <> "/320.png",
      # a step up, where no static file answers first
      "/stock-images/#{id}/#{digest}/..",
      "/stock-images/#{id}/../320.webp",
      "/stock-images/../#{digest}/320.webp",
      # no picture with this id
      "/images/#{Ecto.UUID.generate()}/#{digest}/320.webp",
      "/stock-images/#{id}/#{digest}/320.webp",
      # this picture's id with another digest
      "/images/#{id}/#{String.duplicate("0", 64)}/320.webp"
    ]

    # Under /images a step up never gets that far: the static files, served
    # first, refuse it as a bad request.
    steps_up = [picture <> "/..", "/images/#{id}/../320.webp", "/images/../#{digest}/320.webp"]

    {statuses, events} =
      CallRecord.during(:all, [{Resizer, :_, :_}], fn ->
        for(path <- misses, do: {path, get(conn, path).status}) ++
          for path <- steps_up do
            {status, _headers, _body} = assert_error_sent(400, fn -> get(conn, path) end)
            {path, status}
          end
      end)

    assert Enum.map(statuses, &elem(&1, 1)) == List.duplicate(404, 8) ++ List.duplicate(400, 3),
           inspect(statuses)

    assert events == []

    # The record sees the resizer when an exact address reaches it.
    {hit, events} =
      CallRecord.during(:all, [{Resizer, :_, :_}], fn -> get(conn, picture <> "/320.webp") end)

    assert hit.status == 200
    assert {Resizer, :webp, 2} in CallRecord.calls(events)
  end

  test "PICTURE_HEADERS: a stored picture and its sized copy say a page from them may do nothing",
       %{conn: conn, picture: picture} do
    for {path, type} <- [{picture, "image/jpeg"}, {picture <> "/320.webp", "image/webp"}] do
      answer = get(conn, path)

      assert answer.status == 200
      assert get_resp_header(answer, "content-type") == [type]

      assert get_resp_header(answer, "content-security-policy") == [
               "default-src 'none'; frame-ancestors 'none'"
             ]

      assert get_resp_header(answer, "x-frame-options") == ["DENY"]
      assert get_resp_header(answer, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(answer, "x-content-type-options") == ["nosniff"]
    end
  end
end
