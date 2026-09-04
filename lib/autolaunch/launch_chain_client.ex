defmodule Autolaunch.LaunchChainClient do
  @moduledoc """
  The one Base boundary a direct-wallet launch has.

  `snapshot/1` answers the whole reviewed question at one canonical safe block:
  the admitted factory's identity, its current fee and pause state, the active
  wallet's REGENT balance and its allowance to that factory, the reciprocal
  factory/strategy binding, the strategy's bound fee hook, and the strategy's
  founder-frozen launch terms. There is no partial answer: a review is derived
  from one snapshot or from none.

  `verify/3` is read-only. The browser reports a hash and stops; whether that
  hash confirmed, reverted or contradicted its own review is decided here.
  """

  @type outcome :: %{
          :outcome => :pending | :confirmed | :reverted | :unverified,
          optional(:result) => map()
        }

  @callback snapshot(map()) :: {:ok, map()} | {:error, atom()}
  @callback verify(map(), :approval | :launch, String.t()) :: {:ok, outcome()} | {:error, atom()}

  def module do
    case Application.fetch_env(:autolaunch, :autolaunch_launch_chain_client) do
      {:ok, module} ->
        module

      :error ->
        if Autolaunch.Lab.enabled?(),
          do: Autolaunch.LabLaunchChainClient,
          else: Autolaunch.LaunchRpcClient
    end
  end
end
