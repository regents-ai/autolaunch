defmodule Autolaunch.LaunchChainClient do
  @moduledoc """
  The one Base boundary a direct-wallet launch has.

  `snapshot/1` answers the whole reviewed question at one canonical safe block:
  the admitted factory's identity and pause state, the reciprocal
  factory/strategy binding, the strategy's bound fee hook, and the strategy's
  founder-frozen launch terms. There is no partial answer: a review is derived
  from one snapshot or from none.

  `verify/2` is read-only: whether the transaction `hash` carried out a saved
  review's launch step (`Autolaunch.LaunchOperation`), is still pending,
  reverted, or created a launch other than the one reviewed.
  """

  @type outcome :: %{
          :outcome => :pending | :confirmed | :reverted | :unverified,
          optional(:result) => map()
        }

  @callback snapshot(map()) :: {:ok, map()} | {:error, atom()}
  @callback verify(map(), String.t()) :: {:ok, outcome()} | {:error, atom()}

  def module do
    case Application.fetch_env(:autolaunch, :autolaunch_launch_chain_client) do
      {:ok, module} ->
        module

      :error ->
        Autolaunch.LabLaunchChainClient
    end
  end
end
