defmodule AutolaunchWeb.Plugs.LaunchImageTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.LaunchDraftImageStorage

  test "GET and HEAD serve only an exact immutable ID and digest", %{conn: conn} do
    actor = actor!()
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)
    bytes = jpeg()

    assert {:ok, %{image: image, draft: stored}} =
             LaunchDraftImageStorage.store_and_attach(
               draft,
               bytes,
               "image/jpeg",
               "poster.jpg",
               actor
             )

    path = URI.parse(stored.image).path

    get_conn = get(conn, path)
    assert response(get_conn, 200) == bytes
    assert get_resp_header(get_conn, "content-type") == ["image/jpeg; charset=utf-8"]
    assert get_resp_header(get_conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(get_conn, "etag") == [~s("sha256-#{image.digest}")]
    assert get_resp_header(get_conn, "x-content-type-options") == ["nosniff"]

    head_conn = head(build_conn(), path)
    assert response(head_conn, 200) == ""
    assert get_resp_header(head_conn, "content-length") == [Integer.to_string(byte_size(bytes))]
    assert get_resp_header(head_conn, "x-content-type-options") == ["nosniff"]

    wrong_digest = String.duplicate("0", 64)
    assert response(get(build_conn(), "/images/#{image.id}/#{wrong_digest}"), 404)
    assert response(get(build_conn(), "/images/#{image.id}/#{image.digest}x"), 404)
    assert response(get(build_conn(), "/images/not-a-uuid/#{image.digest}"), 404)
  end

  defp actor! do
    account =
      Accounts.register_verified!(
        "did:privy:launch-image-plug:#{Elixir.System.unique_integer([:positive])}",
        nil,
        [],
        actor: %System{}
      )

    %Human{human_account_id: account.id}
  end

  defp jpeg, do: File.read!("test/support/fixtures/launch-draft.jpg")
end
