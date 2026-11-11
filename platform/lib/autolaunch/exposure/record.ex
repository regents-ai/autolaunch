defmodule Autolaunch.Exposure.Record do
  @moduledoc """
  Looks at one running series and sends at most one transaction for it from
  the recorder's wallet (`Autolaunch.Exposure.Recorder`). A transaction it was
  already sent is settled first, and while the chain has not settled it
  nothing else happens. Then the series' next price decides, exactly as the
  page's Record and Apply panel would (`Autolaunch.Exposure.Steps`):

    * not yet an hour after its time: nothing
    * recordable: `record` it on the oracle, or, once recorded, `settle` it
    * missed (recorded too late, or the feed had no price in time) once the
      recording window has passed: `endOnMissingPrint`
    * no next price: the series has ended, and the row is not looked at again
    * a series the site no longer lists on its chain is not followed any more,
      once its own transaction is settled: one left signed would hold every
      later nonce of the wallet behind it

  The chain is read after the settle, so a price whose `record` has just been
  mined is applied rather than recorded again. Series on one oracle share its
  prices, so while another series' `record` is unsettled a series records
  nothing: once that one is mined, it applies the price instead.
  """

  use Ash.Resource.Change

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Sender
  alias Autolaunch.Exposure.{Chain, Deployment, Recorder, Steps}

  @actor %System{}

  @doc "A row for every series the site lists, so each is followed from the start."
  def follow do
    with {:ok, config} <- Deployment.current() do
      Enum.each(config.series, fn series ->
        Autolaunch.Exposure.add_recording!(%{chain_id: config.chain_id, series: series},
          actor: @actor
        )
      end)
    end
  end

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &record/1)

  defp record(%{data: recording} = changeset) do
    with {:ok, config} <- Deployment.current(),
         {:ok, _block, opts} <- Chain.latest(config.lab),
         chain = %{chain_id: config.chain_id, opts: opts},
         {:ok, :clear} <- Sender.settle(Recorder, chain, %{recording: recording, step: nil}),
         true <- listed?(recording, config) || :unlisted,
         wallet = Recorder.wallet(),
         {:ok, outcome} <- next(recording, wallet, chain) do
      apply_outcome(changeset, outcome)
    else
      :unlisted ->
        apply_outcome(changeset, :ended)

      {:ok, :waiting} ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          "could not record a price for series #{recording.series}: #{refusal(reason)}"
        )
    end
  end

  # A node answers a transaction the wallet cannot pay for as it answers an
  # outage, so every failure names what the wallet holds: an empty wallet
  # never reads as the chain being down.
  defp refusal(reason) do
    wallet = Recorder.wallet()

    held =
      with {:ok, config} <- Deployment.current(),
           opts = Autolaunch.Lab.rpc_opts(config.lab, "autolaunch exposure"),
           {:ok, "0x" <> hex} <-
             Autolaunch.Chain.Rpc.request("eth_getBalance", [wallet.address, "latest"], opts) do
        "holds #{Autolaunch.Chain.Rpc.format_units(String.to_integer(hex, 16), 18)} ETH"
      else
        _unread -> "could not be read"
      end

    "#{inspect(reason)}; the recorder wallet #{wallet.address} #{held}"
  end

  defp listed?(recording, config),
    do:
      recording.chain_id == config.chain_id and
        match?({:ok, _}, Deployment.series(recording.series))

  defp next(recording, wallet, chain) do
    with {:ok, update} <- prepare(recording, :update, wallet) do
      case update do
        %{blocked: :ended} ->
          {:ok, :ended}

        %{blocked: nil, steps: [step | _]} ->
          send_unshared(recording, wallet, chain, step)

        %{blocked: :too_early} ->
          {:ok, :not_yet}

        %{blocked: missed} when missed in [:missed_deadline, :price_too_old] ->
          finish(recording, wallet, chain)
      end
    end
  end

  # A price that can never be applied ends the series once its window has passed.
  defp finish(recording, wallet, chain) do
    with {:ok, ending} <- prepare(recording, :end, wallet) do
      case ending do
        %{blocked: nil, steps: [step]} -> send(recording, wallet, chain, step)
        %{blocked: _not_yet} -> {:ok, :not_yet}
      end
    end
  end

  # A `record` waits while another series' is unsettled: it may be the same price.
  defp send_unshared(recording, wallet, chain, %{step: "record"} = step) do
    if another_record_open?(recording),
      do: {:ok, :not_yet},
      else: send(recording, wallet, chain, step)
  end

  defp send_unshared(recording, wallet, chain, step), do: send(recording, wallet, chain, step)

  defp another_record_open?(recording) do
    {:ok, open} = Autolaunch.Exposure.unsettled_recorder_records(actor: @actor)
    Enum.any?(open, &(&1.recording_id != recording.id))
  end

  defp prepare(recording, kind, wallet),
    do: Steps.prepare(%{kind: kind, series: recording.series}, wallet.address)

  defp send(recording, wallet, chain, %{step: step} = call) do
    owner = %{recording: recording, step: String.to_existing_atom(step)}

    with {:ok, transaction} <- Sender.send_call(Recorder, chain, owner, wallet, call),
         do: {:ok, {:sent, step, transaction}}
  end

  defp apply_outcome(changeset, :not_yet), do: changeset

  defp apply_outcome(changeset, :ended),
    do: Ash.Changeset.force_change_attribute(changeset, :state, :ended)

  defp apply_outcome(%{data: recording} = changeset, {:sent, step, transaction}) do
    Logger.info(
      "exposure price recorder sent #{step} for series #{recording.series}: " <>
        "#{transaction.transaction_hash} (nonce #{transaction.nonce})"
    )

    changeset
  end
end
