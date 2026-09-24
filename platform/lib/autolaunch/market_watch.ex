defmodule Autolaunch.MarketWatch do
  @moduledoc """
  Which auctions one market-feed pass reads.

  A pass reads a bounded page of the open auctions (created, active or ended)
  and, every few passes, a bounded page of the finished ones (graduated or
  failed). Finished auctions still need reading, because the same reading keeps
  their bidders' claim positions and their pool's price current, but they
  change far less often. Each page continues after the last auction the
  previous page read and starts again from the first once it reaches the end,
  so every auction is covered over successive passes however many there are,
  and the work of one pass stays the same.
  """

  alias Autolaunch.Actors.System

  @open_page 100
  @finished_page 100
  @finished_every 4

  @type t :: %{open: String.t() | nil, finished: String.t() | nil, pass: non_neg_integer()}

  @doc "A watch that starts at the first auction of each kind."
  @spec new() :: t()
  def new, do: %{open: nil, finished: nil, pass: 0}

  @doc "This pass's auctions of one kind on one chain, and the watch for the next pass."
  @spec next(t(), pos_integer(), :agent | :stocks) :: {:ok, [struct()], t()} | {:error, term()}
  def next(watch, chain_id, kind) do
    with {:ok, open, open_cursor} <- page(chain_id, kind, false, watch.open, @open_page),
         {:ok, finished, finished_cursor} <- finished(watch, chain_id, kind) do
      {:ok, open ++ finished,
       %{open: open_cursor, finished: finished_cursor, pass: watch.pass + 1}}
    end
  end

  defp finished(%{pass: pass, finished: cursor}, chain_id, kind)
       when rem(pass, @finished_every) == 0,
       do: page(chain_id, kind, true, cursor, @finished_page)

  defp finished(%{finished: cursor}, _chain_id, _kind), do: {:ok, [], cursor}

  # A short page reached the last auction, so the next page starts again from
  # the first.
  defp page(chain_id, kind, finished, cursor, limit) do
    with {:ok, auctions} <-
           Autolaunch.list_market_watch_auctions(chain_id, kind, finished, cursor, limit,
             actor: %System{}
           ) do
      {:ok, auctions, if(length(auctions) < limit, do: nil, else: List.last(auctions).id)}
    end
  end
end
