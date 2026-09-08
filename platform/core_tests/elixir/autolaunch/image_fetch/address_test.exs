defmodule Autolaunch.ImageFetch.AddressTest do
  use ExUnit.Case, async: true

  alias Autolaunch.ImageFetch.Address

  test "IPv4-mapped ::ffff:a.b.c.d is classified as its IPv4" do
    refute Address.public?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 5})
    refute Address.public?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
    assert Address.public?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
  end
end
