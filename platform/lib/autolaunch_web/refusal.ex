defmodule AutolaunchWeb.Refusal do
  @moduledoc """
  A refusal an API route and its hosted MCP tool give alike: the HTTP `status`
  the route answers with, and the `code` and `message` of the error document
  both carry (`AutolaunchWeb.ApiError.body/2`). An answer that refuses returns
  one; the route sends it (`AutolaunchWeb.ApiError.answer/2`), and a hosted tool
  whose action returns it gives that document as its error
  (`AutolaunchWeb.ToolErrors`).
  """
  use Splode.Error, fields: [:status, :code, :message, :hint], class: :unknown

  @doc "The refusal a route answers with `status`, under `code`, in `message`'s words."
  def new(status, code, message, hint \\ nil),
    do: exception(status: status, code: code, message: message, hint: hint)

  def message(%{code: code, message: message}), do: "#{code}: #{message}"
end
