defmodule Autolaunch.Stocks.GeckoTerminal do
  @moduledoc """
  GeckoTerminal's free pool service as the site's jobs read it: the chains it
  reports on, each under its network name there with the launchpad's dollar
  token (USDC on Base, USDG on Robinhood), and one bounded read.

  The free service allows about ten reads a minute, so a refused read waits
  half a minute, then a minute, before it is given up. Only jobs read through
  here; no page waits this long.
  """

  @api "https://api.geckoterminal.com/api/v2"

  @networks %{
    8453 => {"base", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
    4663 => {"robinhood", "0x5fc5360d0400a0fd4f2af552add042d716f1d168"}
  }

  @doc "The chains GeckoTerminal reports on."
  def chain_ids, do: Map.keys(@networks)

  @doc "A chain's network name on GeckoTerminal and its dollar token."
  def network(chain_id), do: Map.fetch!(@networks, chain_id)

  @doc """
  The two tokens of a listed pool as GeckoTerminal names them (`base_0x…`), in
  lowercase and sorted; `nil` for an entry that names no pair.
  """
  def pair(%{"relationships" => relationships}) do
    ~w(base_token quote_token)
    |> Enum.map(fn side ->
      relationships |> get_in([side, "data", "id"]) |> to_string() |> String.downcase()
    end)
    |> Enum.sort()
  end

  def pair(_pool), do: nil

  @doc "One read of a path under the service's address, decoded."
  def get(path) do
    case Req.get(@api <> path,
           headers: [accept: "application/json"],
           redirect: false,
           connect_options: [timeout: 5_000],
           receive_timeout: 15_000,
           retry: :transient,
           retry_delay: &(&1 * 30_000 + 30_000),
           max_retries: 2,
           retry_log_level: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end
end
