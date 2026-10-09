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
      "Check the request against #{PublicDocuments.url("/openapi.json")}. An unknown parameter or value is refused. Sending the same request again will not help."

  defp hint("not_found"),
    do:
      "List what exists with GET #{PublicDocuments.url("/api/v1/auctions")} or GET #{PublicDocuments.url("/api/v1/tokens")}. Every endpoint is described at #{PublicDocuments.url("/openapi.json")}. Sending the same request again will not help."

  defp hint("invalid_amount"),
    do:
      "Send amount as digits with at most one decimal point, no sign, exponent or thousands separator, in the auction's quote token. Sending the same value again will not help."

  defp hint("invalid_max_price"),
    do:
      "Send max_price as digits with at most one decimal point, no sign, exponent or thousands separator: the most you would pay per token, in the auction's quote token. Sending the same value again will not help."

  defp hint(code) when code in ["signed_proof_required", "siwa_unavailable"],
    do:
      "Use your existing signer following https://siwa.regents.sh/skill.md and sign the exact Autolaunch request."

  defp hint("agent_not_paired"),
    do:
      "Ask the owner for a code from https://regents.sh/account, then redeem it with POST /api/agents/v1/pair."

  defp hint("owner_not_local"),
    do: "The owner must sign in at https://autolaunch.sh/profile using the same Privy account."

  defp hint("authentication_required"),
    do:
      "Ask the person to sign in at #{PublicDocuments.url("/")} in this browser, then call again."

  defp hint("chain_unavailable"), do: "Try again in a moment."

  defp hint("internal_error"),
    do:
      "Try again in a moment. If it keeps failing, tell us at #{PublicDocuments.url("/contact")}."

  defp hint(_code),
    do:
      "Every endpoint is described at #{PublicDocuments.url("/openapi.json")} and the agent guide is at #{PublicDocuments.url("/llms.txt")}."
end
