defmodule AutolaunchWeb.FormatTest do
  use ExUnit.Case, async: true

  alias AutolaunchWeb.Format

  test "shortens addresses and hashes consistently" do
    assert Format.short_address("0x1111111111111111111111111111111111111111") ==
             "0x111111...1111"

    assert Format.short_wallet("  0x1111111111111111111111111111111111111111  ") ==
             "0x1111...1111"

    assert Format.short_hash("0x" <> String.duplicate("a", 64)) ==
             "0xaaaaaaaa...aaaaaa"
  end

  test "formats display values without leaking blanks" do
    assert Format.display(nil) == "-"
    assert Format.display(nil, "missing") == "missing"
    assert Format.display("") == "-"
    assert Format.display(42) == "42"
  end

  test "formats contract numbers and currency" do
    assert Format.display_bps_percent(1250) == "12.5%"
    assert Format.display_seconds(30) == "30 seconds"
    assert Format.format_currency("1234.5", 2) == "$1,234.50"
  end

  test "parses decimal values strictly" do
    assert Decimal.equal?(Format.parse_decimal("12.50"), Decimal.new("12.50"))
    assert Format.parse_decimal("12.50 USDC") == nil
    assert Format.parse_decimal("") == nil
  end
end
