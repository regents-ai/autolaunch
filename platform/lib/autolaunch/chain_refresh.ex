defmodule Autolaunch.ChainRefresh do
  @moduledoc """
  Asks every reader of a chain to read it again now, instead of waiting for its
  next turn, as the template's `AshTemplate.ChainRefresh` does.

  The site's background readers of a chain run on a slow clock (five minutes),
  because a node is paid for each call and almost nothing changes between two
  reads. What does change a reading is a person acting: so a confirmed on-chain
  press (`AutolaunchWeb.OnchainSteps.checked/5`, `AutolaunchWeb.OnchainCalls.checked/4`)
  and a press of a page's Refresh call `request/1` with the chain's id.

  Each reader named in this module's `:readers` setting implements `refresh/1`
  and decides for itself how to read again soon: a market feed wakes on every
  machine, a reader of saved rows brings their next read forward. Every reader
  keeps at least ten seconds (`gap_s/0`) between two reads it was asked for, so
  a crowd pressing at once costs one read.
  """

  @doc "Reads the chain again soon, or at once."
  @callback refresh(chain_id :: pos_integer()) :: :ok | {:error, term()}

  @doc "The fewest seconds between two reads that were asked for."
  def gap_s, do: 10

  @doc """
  Asks every reader of chain `chain_id` to read it again. Answers the first
  reader's refusal, after every reader has been asked.
  """
  @spec request(pos_integer()) :: :ok | {:error, term()}
  def request(chain_id) when is_integer(chain_id) and chain_id > 0 do
    Application.fetch_env!(:autolaunch, __MODULE__)[:readers]
    |> Enum.map(& &1.refresh(chain_id))
    |> Enum.find(:ok, &(&1 != :ok))
  end

  @doc "The clock a supervised reader stamps the start of each read with, in milliseconds."
  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)

  @doc """
  How long a supervised reader that last started a read at `read_at` (`now/0`,
  or `nil` before its first) waits before reading again when asked: at once,
  or what is left of the gap.
  """
  @spec wait_ms(integer() | nil) :: non_neg_integer()
  def wait_ms(nil), do: 0
  def wait_ms(read_at), do: max(read_at + gap_s() * 1_000 - now(), 0)

  @doc "Whether a read set for `timer` (or none) comes later than `wait` milliseconds from now."
  @spec later?(reference() | nil, non_neg_integer()) :: boolean()
  def later?(nil, _wait), do: true

  def later?(timer, wait) do
    case Process.read_timer(timer) do
      left when is_integer(left) -> left > wait
      false -> true
    end
  end
end
