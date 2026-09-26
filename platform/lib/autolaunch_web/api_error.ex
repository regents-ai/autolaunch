defmodule AutolaunchWeb.ApiError do
  @moduledoc """
  The one error document the public API answers with, from a controller or
  from an address no controller serves: a stable `code`, the words, and a
  `hint` saying what to do next.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias AutolaunchWeb.PublicDocuments

  @doc "Answers `conn` with `status` and the error document for `code`."
  def send(conn, status, code, message),
    do: conn |> put_status(status) |> json(body(code, message))

  @doc "The error document for `code`, with its hint."
  def body(code, message), do: %{error: %{code: code, message: message, hint: hint(code)}}

  defp hint("invalid_request"),
    do:
      "Check the request against #{PublicDocuments.url("/openapi.json")}. An unknown parameter or value is refused."

  defp hint("not_found"),
    do:
      "List what exists with GET #{PublicDocuments.url("/api/v1/auctions")} or GET #{PublicDocuments.url("/api/v1/tokens")}. Every endpoint is described at #{PublicDocuments.url("/openapi.json")}."

  defp hint("internal_error"),
    do:
      "Try again in a moment. If it keeps failing, tell us at #{PublicDocuments.url("/contact")}."

  defp hint(_code),
    do:
      "Every endpoint is described at #{PublicDocuments.url("/openapi.json")} and the agent guide is at #{PublicDocuments.url("/llms.txt")}."
end
