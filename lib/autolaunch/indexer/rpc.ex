defmodule Autolaunch.Indexer.Rpc do
  @moduledoc """
  The indexer's own JSON-RPC transport, and the redaction boundary around it.

  The endpoint is dedicated to this indexer and separate from the simple-read
  RPC. It never reaches a result, an error, a row or a log line: a failure is
  reported as the method plus a small error class, so a URL carrying a provider
  key cannot escape through a crash report or a captured log.

  A reply counts only as this exchange's own answer: JSON-RPC 2.0, the id that
  was sent, and a result member. Nothing is retried and no redirect is followed,
  so one exchange is one HTTP attempt against the endpoint that was configured.

  The wall-clock ceiling on that attempt is owned here rather than by any
  timeout inside the transport, because a stage timeout bounds a stage and not
  the exchange: an attempt still running at the deadline is killed, and the
  handler's lease is derived from this enforced number.
  """

  require Logger

  @id 1
  @deadline_ms 15_000

  @doc """
  The enforced wall-clock ceiling one exchange can occupy.

  A single exchange never repeats and never travels elsewhere, so this is the
  whole of what one provider request can cost a pass.
  """
  @spec max_request_ms() :: pos_integer()
  def max_request_ms,
    do: Application.get_env(:autolaunch, :autolaunch_indexer_deadline_ms, @deadline_ms)

  @spec request(String.t(), list()) :: {:ok, term()} | {:error, :chain_unavailable}
  def request(method, params) do
    case attempted(method, params) do
      {:ok, response} -> answered(method, response)
      {:error, class} -> failed(method, class)
    end
  end

  # The attempt runs in an unlinked, monitored process that redacts its own
  # outcome before answering, so neither an exit reason nor a crash report can
  # carry the key-bearing endpoint past this boundary. An attempt still running
  # at the deadline is killed rather than left to answer into a later pass.
  defp attempted(method, params) do
    owner = self()
    {pid, ref} = spawn_monitor(fn -> send(owner, {:answer, self(), redacted(method, params)}) end)

    receive do
      {:answer, ^pid, answer} -> settled(ref, answer)
      {:DOWN, ^ref, :process, ^pid, _reason} -> {:error, :transport}
    after
      max_request_ms() -> abandoned(pid, ref)
    end
  end

  defp settled(ref, answer) do
    Process.demonitor(ref, [:flush])
    answer
  end

  defp abandoned(pid, ref) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    {:error, :timeout}
  end

  defp redacted(method, params) do
    case post(method, params) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, class(reason)}
    end
  rescue
    error -> {:error, class(error)}
  end

  defp post(method, params) do
    client().post(url(),
      json: %{jsonrpc: "2.0", id: @id, method: method, params: params},
      redirect: false,
      retry: false
    )
  end

  defp answered(_method, %{
         status: 200,
         body: %{"jsonrpc" => "2.0", "id" => @id, "result" => result}
       }),
       do: {:ok, result}

  # A 200 that is not this exchange's own result is an RPC-level failure; any
  # other status is an HTTP one. Neither body is ever read into a log line.
  defp answered(method, %{status: 200}), do: failed(method, :rpc)
  defp answered(method, _response), do: failed(method, :http)

  defp failed(method, class) do
    Logger.warning(
      "autolaunch indexer chain read failed #{inspect(%{method: method, class: class})}"
    )

    {:error, :chain_unavailable}
  end

  defp class(%Req.TransportError{reason: reason}) when reason in [:timeout, :connect_timeout],
    do: :timeout

  defp class(_reason), do: :transport

  defp client, do: Application.get_env(:autolaunch, :autolaunch_indexer_http_client, Req)
  defp url, do: Application.fetch_env!(:autolaunch, :autolaunch_indexer_rpc_url)
end
