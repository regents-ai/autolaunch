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
    * a series on another chain is not followed any more
    * a series the site no longer lists is not followed any more, once its own
      transaction is settled: one left signed would hold every later nonce of
      the wallet behind it

  The chain is read after the settle, so a price whose `record` has just been
  mined is applied rather than recorded again. Each run warns while the
  wallet runs low, since a node refuses an empty wallet's transaction as it
  would answer an outage.
  """

  use Ash.Resource.Change

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Rpc, Sender}
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
         true <- recording.chain_id == config.chain_id || :unlisted,
         {:ok, _block, opts} <- Chain.latest(config.lab),
         chain = %{chain_id: config.chain_id, opts: opts},
         wallet = Recorder.wallet(),
         :ok <- warn_when_low(wallet, opts),
         {:ok, :clear} <- Sender.settle(Recorder, chain, %{recording: recording, step: nil}),
         true <- match?({:ok, _}, Deployment.series(recording.series)) || :unlisted,
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
          "could not record a price for series #{recording.series}: #{inspect(reason)}"
        )
    end
  end

  # Enough for hundreds of prices at Base's usual fees.
  @low_wei 500_000_000_000_000

  defp warn_when_low(wallet, opts) do
    with {:ok, "0x" <> hex} <- Rpc.request("eth_getBalance", [wallet.address, "latest"], opts),
         {wei, ""} when wei < @low_wei <- Integer.parse(hex, 16) do
      Logger.warning(
        "exposure price recorder wallet #{wallet.address} holds #{Rpc.format_units(wei, 18)} ETH; " <>
          "send it ETH on Base, or its transactions will be refused"
      )
    end

    :ok
  end

  defp next(recording, wallet, chain) do
    with {:ok, update} <- prepare(recording, :update, wallet) do
      case update do
        %{blocked: :ended} ->
          {:ok, :ended}

        %{blocked: nil, steps: [step | _]} ->
          send(recording, wallet, chain, step)

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
