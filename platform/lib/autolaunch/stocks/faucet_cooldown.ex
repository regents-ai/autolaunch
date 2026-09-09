defmodule Autolaunch.Stocks.FaucetCooldown do
  @moduledoc """
  One test-funds grant per wallet and asset within a window.

  `grant/4` runs the send inside one database transaction: the last grant of
  the asset to the wallet (`Autolaunch.Stocks.FaucetGrant`) is read and locked,
  a press inside the window is refused with the time the next one opens, and a
  send that went through replaces the row. A failed send records nothing. A
  window of `0` sends at once and keeps no record.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.Repo
  alias Autolaunch.Stocks.FaucetGrant

  @actor %System{}

  @type send :: (-> {:ok, term()} | {:error, String.t()})

  @spec grant(String.t(), String.t(), non_neg_integer(), send()) ::
          {:ok, term()} | {:error, String.t()}
  def grant(_wallet, _asset, 0, send), do: send.()

  def grant(wallet, asset, seconds, send) when is_integer(seconds) and seconds > 0 do
    Repo.transaction(fn ->
      with :ok <- open(wallet, asset, seconds),
           {:ok, granted} <- send.(),
           {:ok, _record} <- record(wallet, asset) do
        granted
      else
        {:error, message} -> Repo.rollback(message)
      end
    end)
  end

  defp open(wallet, asset, seconds) do
    query =
      FaucetGrant
      |> Ash.Query.for_read(:latest, %{wallet: wallet, asset: asset}, actor: @actor)
      |> Ash.Query.lock(:for_update)

    case Ash.read_one(query) do
      {:ok, nil} ->
        :ok

      {:ok, %FaucetGrant{granted_at: granted_at}} ->
        opens_at = DateTime.add(granted_at, seconds, :second)

        if DateTime.compare(opens_at, DateTime.utc_now()) == :gt,
          do: {:error, refusal(opens_at)},
          else: :ok

      {:error, error} ->
        {:error, "The test-funds record could not be read: #{Exception.message(error)}"}
    end
  end

  defp record(wallet, asset) do
    FaucetGrant
    |> Ash.Changeset.for_create(
      :record,
      %{wallet: wallet, asset: asset, granted_at: DateTime.utc_now()},
      actor: @actor
    )
    |> Ash.create()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, error} ->
        {:error, "The grant was sent but could not be recorded: #{Exception.message(error)}"}
    end
  end

  @doc false
  def refusal(opens_at) do
    "That test asset was already sent to this wallet recently; try again after " <>
      Calendar.strftime(opens_at, "%H:%M") <> " UTC."
  end
end
