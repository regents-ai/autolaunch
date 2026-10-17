defmodule Autolaunch.Stocks.LaunchDraft.Validations.PartialFields do
  @moduledoc false
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Autolaunch.Ticker

  # Bounds are UTF-8 byte sizes, not character counts. Partial text is allowed
  # so autosave never refuses a half-typed field; completeness lives on the
  # resource.
  @limits %{
    name: 64,
    symbol: 16,
    description: 512,
    website: 256,
    telegram: 256,
    discord: 256,
    other_link_1: 256,
    other_link_2: 256,
    other_link_3: 256,
    stock_address: 42
  }

  # The creator's own words and links; the stock is chosen from a list.
  @text_fields [
    :name,
    :symbol,
    :description,
    :website,
    :telegram,
    :discord,
    :other_link_1,
    :other_link_2,
    :other_link_3
  ]
  @multiline [:description]

  @impl true
  def validate(changeset, _opts, _context) do
    errors =
      Enum.flat_map(@limits, fn {field, limit} ->
        if Ash.Changeset.changing_attribute?(changeset, field),
          do: validate_value(field, Ash.Changeset.get_attribute(changeset, field), limit),
          else: []
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_value(_field, nil, _limit), do: []

  defp validate_value(field, value, limit) when is_binary(value) do
    cond do
      not String.valid?(value) -> [error(field, "This text could not be read. Type it again.")]
      field == :symbol and not Ticker.partial?(value) -> [error(field, Ticker.hint())]
      hidden?(field, value) -> [error(field, "Remove the hidden characters from this.")]
      byte_size(value) > limit -> [error(field, too_long(field, limit))]
      true -> []
    end
  end

  defp validate_value(field, _value, _limit),
    do: [error(field, "This text could not be read. Type it again.")]

  # Control characters (a null byte among them, which the draft cannot keep),
  # and the marks that reverse the direction text reads in. A description may
  # keep its line breaks and tabs; every other field is one line.
  defp hidden?(field, value) when field in @multiline,
    do:
      value =~
        ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  defp hidden?(field, value) when field in @text_fields,
    do: value =~ ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  defp hidden?(_field, _value), do: false

  defp too_long(field, limit) when field in @text_fields,
    do: "Too long: up to #{limit} characters, and an emoji counts as several."

  defp too_long(_field, limit), do: "Too long: up to #{limit} characters."

  defp error(field, message), do: InvalidAttribute.exception(field: field, message: message)
end
