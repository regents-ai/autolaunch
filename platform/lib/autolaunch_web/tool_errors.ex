defmodule AutolaunchWeb.ToolErrors do
  @moduledoc """
  What a hosted MCP tool says when its action refuses: the JSON the same refusal
  answers over HTTP, `{"error": {"code", "message", "hint"}}`, as the tool error's
  text (`AshAi.ToToolError`). A connected app's identity refusal takes the site's
  own code and words, the library's `too_many_requests` with `retry_after` when
  it was asked to wait, or, when no answer came, the words every Regent site
  gives it. A failure nobody expected answers `internal_error`, as the API does,
  and is logged by kind alone (`AutolaunchWeb.ReadFailure`).

  Input a tool's action cannot take is refused before AshAi runs it
  (`check_input/3`, the server's `tool_argument_transformer`), with the code the
  same input gets over HTTP: the auction counts' `invalid_request`, a pairing's
  `invalid_request` in the library's words
  (`RegentMCPAgents.pairing_input_refusal/0`), and another identity tool's
  `identity_request_refused`. As AshAi reads it, a call without `input` sends
  none, which is how a tool listed with no inputs is called; an `input` that is
  not an object, `null` and `false` included, is refused like any other.
  """

  alias AutolaunchWeb.ApiError

  @doc """
  Casts a hosted tool's `input` as its action takes it. Input it takes goes on to
  AshAi unchanged; any other is refused as `{:error, text}` with the HTTP code.
  """
  @spec check_input(AshAi.Tool.t(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def check_input(%AshAi.Tool{resource: resource, action: %{name: action}}, arguments, _context) do
    with {:ok, input} <- input(arguments),
         %{valid?: true} <- Ash.ActionInput.for_action(resource, action, input) do
      {:ok, arguments}
    else
      _not_taken -> {:error, refused(action)}
    end
  end

  defp input(%{"input" => %{} = input}), do: {:ok, input}
  defp input(%{} = arguments) when not is_map_key(arguments, "input"), do: {:ok, %{}}
  defp input(_not_an_object), do: :error

  defp refused(:counts),
    do: Jason.encode!(ApiError.body("invalid_request", "The query parameters are invalid."))

  defp refused(:pair_identity),
    do: Jason.encode!(%{error: RegentMCPAgents.pairing_input_refusal()})

  defp refused(_identity), do: Jason.encode!(RegentMCPAgents.Tools.refusal())
end

defimpl AshAi.ToToolError, for: Autolaunch.Agents.Connection.Refused do
  def to_tool_error(%{error: %{} = error, retry_after: retry_after}),
    do: Jason.encode!(%{error: with_retry(error, retry_after)})

  def to_tool_error(%{wait: seconds}) when is_integer(seconds) do
    %{error: error} = RegentMCPAgents.Tools.wait(seconds)
    Jason.encode!(%{error: Map.put(error, :retry_after, seconds)})
  end

  def to_tool_error(_no_answer), do: Jason.encode!(RegentMCPAgents.Tools.refusal())

  defp with_retry(error, retry_after) when is_binary(retry_after) do
    case Integer.parse(retry_after) do
      {seconds, ""} -> Map.put(error, "retry_after", seconds)
      _not_seconds -> error
    end
  end

  defp with_retry(error, _none), do: error
end

defimpl AshAi.ToToolError, for: Ash.Error.Unknown.UnknownError do
  def to_tool_error(error) do
    AutolaunchWeb.ReadFailure.log("hosted tool", error)

    Jason.encode!(
      AutolaunchWeb.ApiError.body("internal_error", "The request could not be completed.")
    )
  end
end
