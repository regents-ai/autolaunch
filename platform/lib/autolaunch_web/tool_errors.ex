defmodule AutolaunchWeb.ToolErrors do
  @moduledoc """
  What a hosted MCP tool says when its action refuses: the JSON the same refusal
  answers over HTTP, `{"error": {"code", "message", "hint"}}`, as the tool error's
  text (`AshAi.ToToolError`). A connected app's identity refusal takes the site's
  own code and words, the library's `too_many_requests` with `retry_after` when
  it was asked to wait, or, when no answer came, the words every Regent site
  gives it. A covered-call refusal takes the covered-call routes' code and words
  (`AutolaunchWeb.CoveredCallsAnswer.body/1`), an Earn refusal the Earn
  routes' (`AutolaunchWeb.EarnAnswer.body/1`), and an agent bid's refusal the
  agent bid routes' (`AutolaunchWeb.AgentBidAnswer.body/1`). Every other tool's
  refusal is its route's own (`AutolaunchWeb.Refusal`). A failure nobody expected answers
  `internal_error`, as the API does, and is logged by kind alone
  (`AutolaunchWeb.ReadFailure`).

  Input a tool's action cannot take is refused before AshAi runs it
  (`check_input/3`, the server's `tool_argument_transformer`), with the code the
  same input gets over HTTP: a bid estimate's own route's answer to the same
  body (`invalid_amount` for an amount that is not text, as there), the other
  market reads', the covered calls', Exposure's, Earn's and agent bids'
  `invalid_request`, each in its own route's words, a draft save's `invalid_draft`, a pairing's
  `invalid_request` in the library's words
  (`RegentMCPAgents.pairing_input_refusal/0`), and another identity tool's
  `identity_request_refused`. As AshAi reads it, a call without `input` sends
  none, which is how a tool listed with no inputs is called; an `input` that is
  not an object, `null` and `false` included, is refused like any other, and so
  is a value of another JSON type than its input takes (the text `"1"` for a
  whole number or `"true"` for true or false, `null` for a text), as the routes
  refuse it: nothing is cast.
  """

  alias AutolaunchWeb.{AccountAnswer, ApiError, ExposureAnswer, MarketAnswer, Refusal}

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
      _not_taken -> {:error, refused(resource, action, arguments)}
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
  defp json_type?(Ash.Type.Boolean, value), do: is_boolean(value)
  # Any other type is the action's own cast to refuse.
  defp json_type?(_type, _value), do: true

  # A bid estimate's input is answered as its route answers the same JSON body,
  # by the route's own code (`MarketAnswer.bid_quote/1`).
  defp refused(Autolaunch.Auction, :bid_quote_answer, %{"input" => %{} = input}),
    do: text(MarketAnswer.bid_quote(input))

  defp refused(resource, action, _arguments), do: refused(resource, action)

  defp refused(Autolaunch.Earn.Product, _earn),
    do: Jason.encode!(AutolaunchWeb.EarnAnswer.body(:invalid_request))

  defp refused(Autolaunch.AgentBid, _bid),
    do: Jason.encode!(AutolaunchWeb.AgentBidAnswer.body(:invalid_request))

  defp refused(_resource, covered_call)
       when covered_call in [:book_answer, :quote, :positions_answer, :prepare_answer],
       do: Jason.encode!(AutolaunchWeb.CoveredCallsAnswer.body(:invalid_request))

  defp refused(Autolaunch.Exposure.Series, _exposure),
    do: text(ExposureAnswer.refusal(:invalid_request))

  defp refused(Autolaunch.TreasurySecurityReport, :treasury_answer),
    do: text(MarketAnswer.invalid_treasury())

  defp refused(Autolaunch.AgentAccount, save)
       when save in [:revstake_draft_save, :memestock_draft_save],
       do: text(AccountAnswer.invalid_draft())

  defp refused(_resource, read)
       when read in [
              :counts,
              :auctions_answer,
              :auction_answer,
              :bid_quote_answer,
              :tokens_answer,
              :token_answer,
              :revstake_draft,
              :memestock_draft,
              :my_positions,
              :points
            ],
       do: text(MarketAnswer.invalid_query())

  defp refused(_resource, :pair_identity),
    do: Jason.encode!(%{error: RegentMCPAgents.pairing_input_refusal()})

  defp refused(_resource, _identity), do: Jason.encode!(RegentMCPAgents.Tools.refusal())

  defp text({:error, refusal}), do: text(refusal)

  defp text(%Refusal{code: code, message: message}),
    do: Jason.encode!(ApiError.body(code, message))
end

defimpl AshAi.ToToolError, for: AutolaunchWeb.Refusal do
  def to_tool_error(%{code: code, message: message}),
    do: Jason.encode!(AutolaunchWeb.ApiError.body(code, message))
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

defimpl AshAi.ToToolError, for: Autolaunch.Earn.Refused do
  def to_tool_error(%{reason: reason}), do: Jason.encode!(AutolaunchWeb.EarnAnswer.body(reason))
end

defimpl AshAi.ToToolError, for: Autolaunch.AgentBid.Refused do
  def to_tool_error(%{reason: reason}),
    do: Jason.encode!(AutolaunchWeb.AgentBidAnswer.body(reason))
end

defimpl AshAi.ToToolError, for: Ash.Error.Unknown.UnknownError do
  def to_tool_error(error) do
    AutolaunchWeb.ReadFailure.log("hosted tool", error)

    Jason.encode!(
      AutolaunchWeb.ApiError.body("internal_error", "The request could not be completed.")
    )
  end
end
