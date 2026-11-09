defmodule Autolaunch.Exposure.Recorder do
  @moduledoc """
  Where the price recorder keeps what it signed: each transaction is an
  `Exposure.RecorderTransaction` of its series' `Exposure.Recording`, sent
  through `Autolaunch.Chain.Sender` from the recorder's own wallet
  (`:exposure_recorder_key`). The owner `Chain.Sender` passes is
  `%{recording: recording, step: step}`.
  """

  @behaviour Autolaunch.Chain.Sender.Ledger

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Wallet

  @actor %System{}

  @doc "The wallet the running site records prices from."
  def wallet, do: Wallet.configured!(:exposure_recorder_key)

  @impl true
  def unsettled(%{recording: recording}),
    do: Autolaunch.Exposure.unsettled_recorder_transaction(recording.id, actor: @actor)

  @impl true
  def highest_nonce(chain_id, signer),
    do: Autolaunch.Exposure.highest_recorder_nonce(chain_id, signer, actor: @actor)

  @impl true
  def record(%{recording: recording, step: step}, attrs),
    do:
      Autolaunch.Exposure.record_recorder_transaction(
        Map.merge(attrs, %{recording_id: recording.id, step: step}),
        actor: @actor
      )

  @impl true
  def settle_transaction(transaction, outcome),
    do: Autolaunch.Exposure.settle_recorder_transaction(transaction, outcome, actor: @actor)

  @impl true
  def label, do: "exposure price recorder"
end
