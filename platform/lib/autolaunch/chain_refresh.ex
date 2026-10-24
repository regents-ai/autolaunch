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
  and decides for itself how to read again soon: a chain head wakes on every
  machine (`Autolaunch.ChainHead`), an Oban reader brings its unique job forward
  (`Autolaunch.ChainWatch.soon/1`). Every reader keeps at least ten seconds
  (`gap_s/0`) between two reads it was asked for, so a crowd pressing at once
  costs one read.
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
end
