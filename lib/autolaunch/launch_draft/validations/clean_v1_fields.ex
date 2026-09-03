defmodule Autolaunch.LaunchDraft.Validations.CleanV1Fields do
  @moduledoc false
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  # Clean-V1 metadata bounds are UTF-8 byte sizes, not character counts.
  @byte_limits [name: 64, symbol: 16, description: 512, website: 256, image: 256]
  @metadata Keyword.keys(@byte_limits)
  @addresses [:treasury]
  @fields @metadata ++ @addresses ++ [:required_regent_raised]
  @required @fields

  @address ~r/\A0x[0-9a-fA-F]{40}\z/
  @zero_address "0x" <> String.duplicate("0", 40)
  @amount ~r/\A[0-9]+(\.[0-9]{1,18})?\z/

  @impl true
  def validate(changeset, _opts, _context) do
    case Enum.flat_map(@fields, &field_errors(&1, Ash.Changeset.get_attribute(changeset, &1))) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp field_errors(field, nil) when field in @required, do: [error(field, "is required")]
  defp field_errors(_field, nil), do: []

  defp field_errors(field, value) when field in @metadata do
    limit = @byte_limits[field]

    cond do
      not String.valid?(value) -> [error(field, "must be readable text")]
      value == "" -> [error(field, "is required")]
      byte_size(value) > limit -> [error(field, "must be #{limit} bytes or fewer")]
      true -> []
    end
  end

  defp field_errors(field, value) when field in @addresses do
    cond do
      not Regex.match?(@address, value) ->
        [error(field, "must start with 0x and hold exactly 40 hexadecimal characters")]

      String.downcase(value) == @zero_address ->
        [error(field, "cannot be the all-zero address")]

      true ->
        []
    end
  end

  defp field_errors(:required_regent_raised, value) do
    cond do
      not Regex.match?(@amount, value) ->
        [
          error(
            :required_regent_raised,
            "must be a plain REGENT amount with at most 18 decimal places"
          )
        ]

      not Regex.match?(~r/[1-9]/, value) ->
        [error(:required_regent_raised, "must be greater than zero")]

      true ->
        []
    end
  end

  defp error(field, message), do: InvalidAttribute.exception(field: field, message: message)
end
