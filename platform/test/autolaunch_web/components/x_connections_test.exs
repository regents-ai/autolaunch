defmodule AutolaunchWeb.Components.XConnectionsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.Components.XConnections

  # pbs.twimg.com answers 351 instead of the picture when the request names
  # autolaunch.sh as its referrer, so connected X pictures showed broken.
  test "a connected X account's picture is requested without naming this site" do
    picture = "https://pbs.twimg.com/profile_images/1/picture_normal.jpg"

    html =
      render_component(&XConnections.x_connections/1,
        id: "connections",
        enabled: true,
        connections: [
          %{
            role: :profile,
            username: "seanwbren",
            display_name: "Sean",
            avatar_url: picture,
            verified_at: DateTime.utc_now(),
            intent_sequence: 1
          }
        ]
      )

    img = html |> LazyHTML.from_fragment() |> LazyHTML.query("#connections-profile img")

    assert LazyHTML.attribute(img, "src") == [picture]
    assert LazyHTML.attribute(img, "referrerpolicy") == ["no-referrer"]
  end
end
