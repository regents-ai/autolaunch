defmodule AutolaunchWeb.ToolErrors do
  @moduledoc """
  What a hosted MCP tool says when its action refuses: the JSON the same refusal
  answers over HTTP, `{"error": {"code", "message", "hint"}}`, as the tool error's
  text (`AshAi.ToToolError`). A connected app's identity refusal takes the site's
  own code and words, the library's `too_many_requests` with `retry_after` when
  it was asked to wait, or, when no answer came, the words every Regent site
  gives it. A covered-call refusal takes the covered-call routes' code and words
  (`AutolaunchWeb.CoveredCallsAnswer.body/1`). A failure nobody expected answers `internal_error`, as the API does,
  and is logged by kind alone (`AutolaunchWeb.ReadFailure`).

  Input a tool's action cannot take is refused before AshAi runs it
  (`check_input/3`, the server's `tool_argument_transformer`), with the code the
  same input gets over HTTP: the auction counts' and the covered calls'
  `invalid_request`, each in its own route's words, a pairing's
  `invalid_request` in the library's words
  (`RegentMCPAgents.pairing_input_refusal/0`), and another identity tool's
  `identity_request_refused`. As AshAi reads it, a call without `input` sends
  none, which is how a tool listed with no inputs is called; an `input` that is
  not an object, `null` and `false` included, is refused like any other, and so
  is a value of another JSON type than its input takes (the text `"1"` for a
  whole number, `null` for a text), as the routes refuse it: nothing is cast.
  """

  alias AutolaunchWeb.ApiError

  @doc """
  Casts a hosted tool's `input` as its action takes it. Input it takes goes on to
  AshAi unchanged; any other is refused as `{:error, text}` with the HTTP code.
  """
  @spec check_input(AshAi.Tool.t(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def check_input(
        %AshAi.Tool{resource: resource, action: %{name: action, arguments: taken}},
        arguments,
        _context
      ) do
    with {:ok, input} <- input(arguments),
         true <- Enum.all?(input, &typed?(&1, taken)),
         %{valid?: true} <- Ash.ActionInput.for_action(resource, action, input) do
      {:ok, arguments}
    else
      _not_taken -> {:error, refused(action)}
    end
  end

  defp input(%{"input" => %{} = input}), do: {:ok, input}
  defp input(%{} = arguments) when not is_map_key(arguments, "input"), do: {:ok, %{}}
  defp input(_not_an_object), do: :error

  # Each value given has the JSON type its argument takes; a name the action does
  # not take is refused by the action itself.
  defp typed?({name, value}, taken) do
    case Enum.find(taken, &(Atom.to_string(&1.name) == name)) do
      nil -> true
      %{type: type} -> json_type?(type, value)
    end
  end

  defp json_type?(Ash.Type.Integer, value), do: is_integer(value)
  defp json_type?(Ash.Type.String, value), do: is_binary(value)
  defp json_type?(Ash.Type.Atom, value), do: is_binary(value)

  defp refused(covered_call)
       when covered_call in [:book_answer, :quote, :positions_answer, :prepare_answer],
       do: Jason.encode!(AutolaunchWeb.CoveredCallsAnswer.body(:invalid_request))

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

defimpl AshAi.ToToolError, for: Autolaunch.CoveredCalls.Refused do
  def to_tool_error(%{reason: reason}),
    do: Jason.encode!(AutolaunchWeb.CoveredCallsAnswer.body(reason))
end

defimpl AshAi.ToToolError, for: Ash.Error.Unknown.UnknownError do
  def to_tool_error(error) do
    AutolaunchWeb.ReadFailure.log("hosted tool", error)

    Jason.encode!(
      AutolaunchWeb.ApiError.body("internal_error", "The request could not be completed.")
    )
  end
end
