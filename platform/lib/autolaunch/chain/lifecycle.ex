defmodule Autolaunch.Chain.Lifecycle do
  @moduledoc """
  The launch lifecycle every Autolaunch launch contract records as one number:
  the Revstake strategy's `distribution(auction).lifecycle`, and the Memestock
  and Robinhood launchpads' `launches(id).lifecycle`. 0 is no launch, 1 an
  auction still running, 2 graduated (its pool exists) and 3 failed. Both
  finished values are written only inside `migrate`.

  This is the one place the numbers are read; everything else names the state.
  """

  @states %{0 => :none, 1 => :active, 2 => :graduated, 3 => :failed}

  @type t :: :none | :active | :graduated | :failed

  @doc "The state a recorded lifecycle number names, or `:error` for any other number."
  @spec fetch(non_neg_integer()) :: {:ok, t()} | :error
  def fetch(number), do: Map.fetch(@states, number)

  @doc "Whether a recorded lifecycle number says the launch graduated."
  @spec graduated?(non_neg_integer()) :: boolean()
  def graduated?(number), do: fetch(number) == {:ok, :graduated}
end
