defmodule AutolaunchWeb.CoveredCallsController do
  @moduledoc """
  Covered calls over HTTP for anyone, and for the person signed in on this
  site: a market's book and a suggested premium need no account; the
  signed-in person's own listings and holdings are read for the wallet they
  signed in with. Each calls the same `Autolaunch.CoveredCalls` operation the
  page and the agent routes call (`AutolaunchWeb.CoveredCallsAnswer`).
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Actors.Human
  alias Autolaunch.CoveredCalls
  alias AutolaunchWeb.CoveredCallsAnswer, as: Answer

  def book(conn, %{"symbol" => symbol} = params) do
    if map_size(params) == 1,
      do: Answer.send(conn, CoveredCalls.covered_call_book(symbol, actor: nil), :book),
      else: Answer.refuse(conn, :invalid_request)
  end

  def quote(conn, %{"symbol" => symbol}) do
    case conn.body_params do
      %{"strike_per_token" => strike, "expiry" => expiry} = body
      when map_size(body) == 2 and is_integer(strike) and is_integer(expiry) ->
        Answer.send(
          conn,
          CoveredCalls.covered_call_quote(symbol, strike, expiry, actor: nil),
          :quote
        )

      _other ->
        Answer.refuse(conn, :invalid_request)
    end
  end

  def mine(%{assigns: %{current_human_account: nil}} = conn, _params),
    do: Answer.refuse(conn, :authentication_required)

  def mine(%{assigns: %{current_human_account: account}} = conn, %{"symbol" => symbol}) do
    actor = %Human{human_account_id: account.id}
    Answer.send(conn, CoveredCalls.covered_call_positions(symbol, actor: actor), :positions)
  end
end
