defmodule AutolaunchWeb.ErrorJSON do
  @moduledoc """
  The error document a JSON request receives when it never reaches a
  controller: an unknown address, an unreadable body, a crash. Under `/api`
  every error is JSON, whatever the request asked for.
  """

  alias AutolaunchWeb.ApiError

  def render(template, _assigns), do: ApiError.body(code(template), message(template))

  defp code("400.json"), do: "invalid_request"
  defp code("404.json"), do: "not_found"
  defp code("500.json"), do: "internal_error"

  defp code(template),
    do:
      template
      |> Phoenix.Controller.status_message_from_template()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")

  defp message("400.json"), do: "The request could not be read."
  defp message("404.json"), do: "There is nothing at this address."
  defp message("500.json"), do: "The request could not be completed."
  defp message(template), do: Phoenix.Controller.status_message_from_template(template) <> "."
end
