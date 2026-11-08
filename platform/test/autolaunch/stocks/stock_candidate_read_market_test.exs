defmodule Autolaunch.Stocks.StockCandidateReadMarketTest do
  # A market read whose chain node does not answer is one warning line, never an
  # error: the row's turn still moves on and nothing it found before is touched,
  # so it is read again when its turn comes (Sentinel, 29 Oct 2026 18:05Z). An
  # answer in another shape still fails the read.
  use Autolaunch.DataCase, async: false

  import ExUnit.CaptureLog

  @actor %Autolaunch.Actors.System{}
  @feed "0x" <> String.duplicate("ab", 20)

  # GeckoTerminal's search answers, with no pools, so the read goes on to the chain.
  setup do
    previous = Req.default_options()
    Req.default_options(plug: &Req.Test.json(&1, %{"data" => []}))
    on_exit(fn -> Req.default_options(previous) end)

    {:ok, candidate} =
      Autolaunch.list_stock_candidate(%{chain_id: 8453, ticker: "AMZN", feed: @feed},
        actor: @actor
      )

    %{candidate: candidate}
  end

  defmodule WrongShape do
    @moduledoc "A node that answers every request with something that is not a quantity."
    def post(_url, _options), do: {:ok, %{status: 200, body: %{"result" => "not a number"}}}
  end

  test "a chain node that does not answer is one warning, and the row's turn moves on", %{
    candidate: candidate
  } do
    chain_answers_with(Autolaunch.BaseRpcStub.Timeout)

    log =
      capture_log([level: :warning], fn -> assert {:ok, _read} = read_market(candidate) end)

    # The row as stored: its turn was taken, and nothing a read finds was written.
    stored = Ash.get!(Autolaunch.Stocks.StockCandidate, candidate.id, actor: @actor)
    assert candidate.tried_at == nil
    assert %DateTime{} = stored.tried_at
    assert stored.read_at == nil
    assert stored.status == candidate.status

    assert log =~ "stock candidate AMZN not read: a chain read failed"
    refute log =~ "[error]"
  end

  test "a chain answer in another shape still fails the read", %{candidate: candidate} do
    chain_answers_with(WrongShape)

    assert {:error, error} = read_market(candidate)
    assert Exception.message(error) =~ "stock candidate read failed: :invalid_chain_response"
  end

  defp chain_answers_with(client) do
    previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, client)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
        else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
    end)
  end

  defp read_market(candidate) do
    candidate
    |> Ash.Changeset.for_update(:read_market, %{}, actor: @actor)
    |> Ash.update()
  end
end
