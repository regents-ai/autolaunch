defmodule Autolaunch.LaunchReviews do
  @moduledoc """
  Lists a launch the chain shows for the account whose saved review it carried
  out: a Revstake launch (`:launch`, `Autolaunch.LaunchOperation`) or a
  Memestake launch (`:stocks_launch`, `Autolaunch.Stocks.LaunchOperation`).

  A review carried out a launch when the launch's transaction is its signer's,
  sent to its step's target with its step's exact calldata, and the launch the
  receipt records is the one it reviewed. The match projects the launch and
  marks the review `chain_verified`; doing it twice changes nothing.

  `recover/2` answers for a launch discovered on chain; `confirm/3` for the one
  a page saw its own press confirm.
  """

  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.{LabProjection, LaunchChainClient, LaunchOperation}
  alias Autolaunch.Stocks.LabLaunchChainClient
  alias Autolaunch.Stocks.LabProjection, as: StocksLabProjection
  alias Autolaunch.Stocks.LaunchOperation, as: StocksLaunchOperation

  @system %System{}

  # A read that cannot be this review's transaction.
  @not_this_review [:transaction_mismatch, :invalid_confirmation]

  @type kind :: :launch | :stocks_launch
  @type answer :: {:listed, integer(), map()} | {:unlisted, atom()} | {:pending, term()}

  @doc """
  Matches a launch the chain shows to the saved reviews of its launcher on its
  chain, newest first: `{:listed, account_id, result}` for the review it
  carried out, with the launch the chain records,
  `{:unlisted, :no_matching_review}` when none did, or `{:pending, reason}`
  while the chain cannot answer yet.
  """
  @spec recover(kind(), map()) :: answer()
  def recover(kind, %{chain_id: chain_id, launcher: launcher, transaction_hash: hash}) do
    case candidates(kind, chain_id, launcher) do
      {:ok, reviews} -> match(kind, reviews, String.downcase(hash), :no_matching_review)
      {:error, reason} -> {:pending, reason}
    end
  end

  @doc "Lists the launch the saved review `action_id` carried out as `hash`."
  @spec confirm(kind(), String.t(), String.t()) :: answer()
  def confirm(kind, action_id, hash) do
    case resource(kind)
         |> Ash.Query.filter(action_id == ^action_id)
         |> Ash.read_one(actor: @system) do
      {:ok, nil} -> {:unlisted, :no_matching_review}
      {:ok, review} -> match(kind, [review], String.downcase(hash), :no_matching_review)
      {:error, reason} -> {:pending, reason}
    end
  end

  defp candidates(kind, chain_id, launcher) do
    with {:ok, reviews} <-
           resource(kind)
           |> Ash.Query.filter(string_downcase(signer) == ^String.downcase(launcher))
           |> Ash.Query.sort(inserted_at: :desc)
           |> Ash.read(actor: @system) do
      {:ok, Enum.filter(reviews, &match?(%{"chain" => %{"chain_id" => ^chain_id}}, &1.review))}
    end
  end

  defp match(_kind, [], _hash, :no_matching_review), do: {:unlisted, :no_matching_review}
  defp match(_kind, [], _hash, reason), do: {:pending, reason}

  defp match(kind, [review | rest], hash, waiting) do
    case client(kind).verify(review.review, hash) do
      {:ok, %{outcome: :confirmed, result: result}} -> adopt(kind, review.id, result)
      {:ok, %{outcome: :pending}} -> match(kind, rest, hash, :chain_pending)
      {:ok, %{outcome: _not_this_review}} -> match(kind, rest, hash, waiting)
      {:error, reason} when reason in @not_this_review -> match(kind, rest, hash, waiting)
      {:error, reason} -> match(kind, rest, hash, reason)
    end
  end

  # Under the review's lock, so a page's confirmation and discovery of the same
  # launch are one after the other. The listing's notifications are sent once
  # the transaction has committed.
  defp adopt(kind, id, result) do
    Ash.transaction(resource(kind), fn ->
      with {:ok, review} <- locked(kind, id),
           {:ok, notifications} <- project(kind, review, result),
           {:ok, review} <- verified(review, result) do
        {review.human_account_id, result, notifications}
      else
        {:error, reason} -> Ash.DataLayer.rollback(resource(kind), reason)
      end
    end)
    |> case do
      {:ok, {account_id, result, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:listed, account_id, result}

      {:error, error} ->
        {:pending, error}
    end
  end

  defp locked(kind, id) do
    resource(kind)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @system)
  end

  # A review withdrawn before its launch landed stays withdrawn; the launch is
  # still listed.
  defp verified(%{state: :prepared} = review, result) do
    review
    |> Ash.Changeset.for_update(:verify, %{result: result}, actor: @system)
    |> Ash.update(actor: @system)
  end

  defp verified(review, _result), do: {:ok, review}

  defp project(:launch, review, result), do: LabProjection.project_launch(review, result)

  defp project(:stocks_launch, review, result),
    do: StocksLabProjection.project_launch(review, result)

  defp resource(:launch), do: LaunchOperation
  defp resource(:stocks_launch), do: StocksLaunchOperation

  defp client(:launch), do: LaunchChainClient.module()
  defp client(:stocks_launch), do: LabLaunchChainClient
end
