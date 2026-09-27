defmodule AutolaunchWeb.TokenDisplayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.TokenDisplay

  # A long Revstake price once carried every digit into its hover and
  # screen-reader text; both now carry the short figure shown on screen.
  test "a long price gives its short figure to the hover and screen-reader text" do
    html = render_component(&TokenDisplay.price/1, amount: "0.000000012345678901234567")

    assert html =~ ~s(title="0.00000001235")
    assert html =~ ~r/class="[^"]*visually-hidden[^"]*">\s*0.00000001235\s*</
    refute html =~ "12345678901234567"
  end
end
