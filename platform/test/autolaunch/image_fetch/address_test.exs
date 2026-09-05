defmodule Autolaunch.ImageFetch.AddressTest do
  use ExUnit.Case, async: true

  alias Autolaunch.ImageFetch.Address

  test "IPv4 public addresses" do
    assert Address.public?({8, 8, 8, 8})
    assert Address.public?({1, 1, 1, 1})
    assert Address.public?({172, 15, 0, 1})
    assert Address.public?({172, 32, 0, 1})
  end

  test "IPv4 loopback 127/8" do
    refute Address.public?({127, 0, 0, 1})
    refute Address.public?({127, 255, 255, 255})
  end

  test "IPv4 private 10/8, 172.16/12, 192.168/16" do
    refute Address.public?({10, 0, 0, 5})
    refute Address.public?({172, 16, 0, 1})
    refute Address.public?({172, 31, 255, 255})
    refute Address.public?({192, 168, 1, 1})
  end

  test "IPv4 link-local 169.254/16" do
    refute Address.public?({169, 254, 0, 1})
  end

  test "IPv4 multicast 224/4" do
    refute Address.public?({224, 0, 0, 1})
    refute Address.public?({239, 255, 255, 255})
  end

  test "IPv4 unspecified and broadcast" do
    refute Address.public?({0, 0, 0, 0})
    refute Address.public?({255, 255, 255, 255})
  end

  test "IPv6 public addresses" do
    assert Address.public?({0x2606, 0x4700, 0, 0, 0, 0, 0, 1})
    assert Address.public?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
  end

  test "IPv6 loopback and unspecified" do
    refute Address.public?({0, 0, 0, 0, 0, 0, 0, 1})
    refute Address.public?({0, 0, 0, 0, 0, 0, 0, 0})
  end

  test "IPv6 link-local fe80::/10" do
    refute Address.public?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    refute Address.public?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
  end

  test "IPv6 unique-local fc00::/7" do
    refute Address.public?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
    refute Address.public?({0xFDFF, 0, 0, 0, 0, 0, 0, 1})
  end

  test "IPv6 multicast ff00::/8" do
    refute Address.public?({0xFF00, 0, 0, 0, 0, 0, 0, 1})
    refute Address.public?({0xFFFF, 0, 0, 0, 0, 0, 0, 1})
  end

  test "IPv4-mapped ::ffff:a.b.c.d is classified as its IPv4" do
    refute Address.public?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 5})
    refute Address.public?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
    assert Address.public?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
  end
end
