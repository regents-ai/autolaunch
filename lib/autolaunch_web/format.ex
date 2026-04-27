defmodule AutolaunchWeb.Format do
  @moduledoc false

  alias Decimal, as: D

  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value

  def display(value, empty \\ "-")

  def display(nil, empty), do: empty
  def display("", empty), do: empty
  def display(value, _empty) when is_binary(value), do: value
  def display(value, _empty), do: to_string(value)

  def display_uint(value), do: display(value, "n/a")
  def display_int(value), do: display(value, "n/a")

  def display_seconds(nil), do: "n/a"
  def display_seconds(value) when is_integer(value), do: Integer.to_string(value) <> " seconds"
  def display_seconds(value), do: to_string(value)

  def display_bps_percent(nil), do: "n/a"
  def display_bps_percent(0), do: "n/a"

  def display_bps_percent(value) when is_integer(value) do
    value
    |> D.new()
    |> D.div(D.new(100))
    |> D.normalize()
    |> D.to_string(:normal)
    |> Kernel.<>("%")
  end

  def display_bps_percent(value), do: to_string(value)

  def display_unix_timestamp(nil), do: "n/a"
  def display_unix_timestamp(0), do: "n/a"

  def display_unix_timestamp(value) when is_integer(value) and value > 0 do
    value
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  rescue
    _ -> Integer.to_string(value)
  end

  def display_unix_timestamp(value), do: to_string(value)

  def display_datetime(nil), do: nil

  def display_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p UTC")
      _ -> value
    end
  end

  def display_chart_date(%DateTime{} = value), do: Calendar.strftime(value, "%b %-d, %Y")
  def display_chart_date(nil), do: "Scheduled date"

  def display_chart_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%b %-d, %Y")
      _ -> value
    end
  end

  def yes_no(true), do: "yes"
  def yes_no(false), do: "no"
  def yes_no(nil), do: "n/a"

  def humanize_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def short_address(value, empty \\ "n/a")

  def short_address(nil, empty), do: empty

  def short_address("0x" <> _rest = value, _empty) when byte_size(value) > 12 do
    String.slice(value, 0, 8) <> "..." <> String.slice(value, -4, 4)
  end

  def short_address(value, _empty), do: to_string(value)

  def short_wallet(nil), do: nil

  def short_wallet(wallet) when is_binary(wallet) do
    wallet
    |> String.trim()
    |> do_short_wallet()
  end

  def short_wallet(_wallet), do: nil

  defp do_short_wallet("0x" <> rest = wallet) when byte_size(rest) > 10 do
    String.slice(wallet, 0, 6) <> "..." <> String.slice(wallet, -4, 4)
  end

  defp do_short_wallet(wallet), do: wallet

  def short_hash(value, empty \\ "none")

  def short_hash(nil, empty), do: empty

  def short_hash("0x" <> _rest = value, _empty) when byte_size(value) > 14 do
    String.slice(value, 0, 10) <> "..." <> String.slice(value, -6, 6)
  end

  def short_hash(value, _empty), do: to_string(value)

  def parse_decimal(nil), do: nil
  def parse_decimal(""), do: nil
  def parse_decimal(value) when is_integer(value), do: D.new(value)
  def parse_decimal(%D{} = value), do: value

  def parse_decimal(value) when is_binary(value) do
    case D.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  def parse_decimal(_value), do: nil

  def format_currency(nil, _places), do: "Unavailable"

  def format_currency(value, places) do
    case parse_decimal(value) do
      nil ->
        "Unavailable"

      decimal ->
        "$" <>
          (decimal
           |> D.round(places)
           |> decimal_to_string(places)
           |> add_delimiters())
    end
  end

  def decimal_to_string(decimal, 0), do: decimal |> D.round(0) |> D.to_string(:normal)

  def decimal_to_string(decimal, places) do
    string = D.to_string(decimal, :normal)

    case String.split(string, ".", parts: 2) do
      [whole, fraction] ->
        padded =
          fraction
          |> String.pad_trailing(places, "0")
          |> String.slice(0, places)

        whole <> "." <> padded

      [whole] ->
        whole <> "." <> String.duplicate("0", places)
    end
  end

  def add_delimiters("-" <> rest), do: "-" <> add_delimiters(rest)

  def add_delimiters(value) do
    case String.split(value, ".", parts: 2) do
      [whole, fraction] -> add_delimiters_to_whole(whole) <> "." <> fraction
      [whole] -> add_delimiters_to_whole(whole)
    end
  end

  defp add_delimiters_to_whole(whole) do
    whole
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
