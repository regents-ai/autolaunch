defmodule Autolaunch.LaunchDraft.Validations.PartialFields do
  @moduledoc false
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @limits %{
    name: 64,
    symbol: 16,
    description: 512,
    website: 256,
    image: 256,
    treasury: 42,
    required_regent_raised: 128,
    eoa_acknowledgement: 512
  }

  @impl true
  def validate(changeset, _opts, _context) do
    errors =
      Enum.flat_map(@limits, fn {field, limit} ->
        if Ash.Changeset.changing_attribute?(changeset, field) do
          validate_value(field, Ash.Changeset.get_attribute(changeset, field), limit)
        else
          []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_value(_field, nil, _limit), do: []

  defp validate_value(field, value, limit) when is_binary(value) do
    cond do
      not String.valid?(value) -> [error(field, "must be readable text")]
      byte_size(value) > limit -> [error(field, "must be #{limit} bytes or fewer")]
      true -> []
    end
  end

  defp validate_value(field, _value, _limit), do: [error(field, "must be readable text")]

  defp error(field, message), do: InvalidAttribute.exception(field: field, message: message)
end
