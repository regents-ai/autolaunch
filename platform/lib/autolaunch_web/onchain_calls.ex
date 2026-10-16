defmodule AutolaunchWeb.OnchainCalls do
  @moduledoc """
  The server half of a review the wallet sends as one atomic batch, beside
  `AutolaunchWeb.OnchainSteps` for reviews sent one step at a time.

  The page asks Privy's active wallet whether it can send calls together on the
  review's chain (EIP-5792 `wallet_getCapabilities`, `atomic` supported or
  ready) and reports the answer for the review on the page (`atomic/2`). Only
  then does the panel offer one press for every step; otherwise the steps go
  one at a time, as before. A batch is offered only before any step of the
  review was sent on its own, since a batch repeating a sent step could revert.

  A press sends every step of the review in one `wallet_sendCalls` request with
  `atomicRequired`. The page reports the wallet's batch id (`sent/3`), then the
  one transaction the wallet's `wallet_getCallsStatus` receipts name, asking
  the wallet every quarter second (`landed/2`), or that the wallet sent nothing (`failed/2`) or gave no receipt
  in time (`unconfirmed/2`). From the hash on, the server reads that
  transaction at the latest block every two seconds, and only it says what
  happened (`Autolaunch.Chain.Calls.outcome/4`). Nothing is kept beyond the
  page.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Autolaunch.Chain.Calls
  alias AutolaunchWeb.OnchainSteps

  @recheck_ms 2_000
  @read_limit 90
  @kept 8

  @doc "The assigns a panel that may batch starts with."
  def init(socket), do: assign(socket, atomic: nil, batches: [])

  @doc """
  The wallet's answer for the review on the page: `atomic` is whether it can
  send the review's calls together. An answer for another review is dropped.
  """
  def atomic(%{assigns: %{review: %{id: id}}} = socket, %{"review_id" => id, "atomic" => atomic})
      when is_boolean(atomic),
      do: assign(socket, atomic: if(atomic, do: id))

  def atomic(socket, _params), do: socket

  @doc "Whether the review on the page goes as one batch."
  def offered?(%{review: nil}), do: false

  def offered?(%{review: review, atomic: atomic, batches: batches, presses: presses}) do
    atomic == review.id and
      (Enum.any?(batches, &(&1.review.id == review.id)) or
         Enum.all?(review.steps, &is_nil(OnchainSteps.entry(presses, review, &1.step))))
  end

  @doc "The newest batch sent from `review`, or `nil`."
  def newest(batches, %{id: id}), do: Enum.find(batches, &(&1.review.id == id))
  def newest(_batches, nil), do: nil

  @doc """
  What the newest batch from the review on the page is doing, in the states
  the review's steps show: `:ready` (none sent, or the wallet sent nothing),
  `:sent`, `:stalled`, `:done`, `:reverted` or `:other` (a transaction that is
  not this review's).
  """
  def state(nil), do: :ready
  def state(%{outcome: :failed}), do: :ready
  def state(%{outcome: outcome}) when outcome in [:sent, :unconfirmed], do: :sent
  def state(%{outcome: :pending, reads: reads}) when reads >= @read_limit, do: :stalled
  def state(%{outcome: :pending}), do: :sent
  def state(%{outcome: outcome}) when outcome in [:confirmed, :nothing], do: :done
  def state(%{outcome: :reverted}), do: :reverted
  def state(%{outcome: :not_this_step}), do: :other

  @doc """
  The wallet took a batch from the review on the page; it waits for its
  receipt. `proof` is the event the batch must write for the signer
  (`Autolaunch.Chain.Calls.outcome/4`).
  """
  def sent(
        %{assigns: %{review: %{id: id} = review}} = socket,
        %{"review_id" => id, "calls_id" => calls_id},
        proof
      )
      when is_binary(calls_id) and byte_size(calls_id) in 1..1024 and is_map(proof) do
    entry = %{id: calls_id, review: review, proof: proof, hash: nil, outcome: :sent, reads: 0}

    assign(socket,
      batches:
        Enum.take([entry | Enum.reject(socket.assigns.batches, &(&1.id == calls_id))], @kept),
      press_note: nil
    )
  end

  def sent(socket, _params, _proof), do: socket

  @doc """
  The wallet's status report named the batch's transaction; the server reads it
  from now on.
  """
  def landed(socket, %{"calls_id" => calls_id, "transaction_hash" => hash})
      when is_binary(hash) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, hash) do
      with_entry(socket, calls_id, [:sent, :unconfirmed], fn entry ->
        entry = %{entry | hash: String.downcase(hash), outcome: :pending, reads: 0}
        {entry, &check(&1, entry)}
      end)
    else
      socket
    end
  end

  def landed(socket, _params), do: socket

  @doc "The wallet reported that it sent nothing of the batch."
  def failed(socket, %{"calls_id" => calls_id}),
    do: with_entry(socket, calls_id, [:sent], &{%{&1 | outcome: :failed}, nil})

  def failed(socket, _params), do: socket

  @doc "The wallet gave no receipt for the batch while the page waited."
  def unconfirmed(socket, %{"calls_id" => calls_id}),
    do: with_entry(socket, calls_id, [:sent], &{%{&1 | outcome: :unconfirmed}, nil})

  def unconfirmed(socket, _params), do: socket

  @doc "Starts reading a batch again after the page stopped on its own."
  def check_again(socket, hash) do
    case Enum.find(socket.assigns.batches, &(&1.hash == hash and state(&1) == :stalled)) do
      nil ->
        socket

      entry ->
        with_entry(socket, entry.id, [:pending], fn entry ->
          entry = %{entry | reads: 0}
          {entry, &check(&1, entry)}
        end)
    end
  end

  @doc "Whether `hash` is a batch's transaction this page follows."
  def follows?(batches, hash), do: Enum.any?(batches, &(&1.hash == hash))

  @doc """
  One answer from `handle_async({:onchain_calls, calls_id}, result, socket)`.
  `confirmed` runs once, with the entry, when the batch lands and succeeds.
  """
  def checked(socket, calls_id, result, confirmed) do
    answer =
      case result do
        {:ok, answer} -> answer
        {:exit, _reason} -> :unanswered
      end

    with_entry(socket, calls_id, [:pending], fn entry ->
      entry = %{entry | outcome: outcome(answer), reads: entry.reads + 1}

      cond do
        entry.outcome == :pending and entry.reads < @read_limit -> {entry, &check(&1, entry)}
        entry.outcome in [:confirmed, :nothing] -> {entry, &confirmed.(&1, entry)}
        true -> {entry, nil}
      end
    end)
  end

  defp outcome({:ok, outcome}) when outcome in [:pending, :confirmed, :nothing, :reverted],
    do: outcome

  defp outcome({:error, :not_this_step}), do: :not_this_step
  defp outcome(_unanswered), do: :pending

  defp with_entry(socket, calls_id, outcomes, change) do
    case Enum.find(socket.assigns.batches, &(&1.id == calls_id and &1.outcome in outcomes)) do
      nil ->
        socket

      entry ->
        {entry, next} = change.(entry)
        batches = Enum.map(socket.assigns.batches, &if(&1.id == calls_id, do: entry, else: &1))
        socket = assign(socket, batches: batches)
        if next, do: next.(socket), else: socket
    end
  end

  defp check(socket, %{id: calls_id, hash: hash, reads: reads, review: review, proof: proof}) do
    start_async(socket, {:onchain_calls, calls_id}, fn ->
      if reads > 0, do: Process.sleep(@recheck_ms)
      Calls.outcome(review, hash, proof)
    end)
  end
end
