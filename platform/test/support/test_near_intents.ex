defmodule Autolaunch.TestNearIntents do
  @moduledoc """
  A stand-in for `RegentNearIntents`, answering in its shapes from the 1Click
  service's own answers (`test/support/fixtures/near_intents`): its token list,
  and the dry quote of 14 Nov 2026 for 5 USDC on Base, with a deposit address
  added when the quote is not dry and a deadline `deadline_in` seconds from
  now, an hour unless the test says otherwise. A swap's status is what the test
  scripts. Every quote asked for is recorded, newest first. It is never
  installed outside a test.
  """

  @key :near_intents_fixture
  @fixtures Path.expand("fixtures/near_intents", __DIR__)
  @quote @fixtures |> Path.join("quote.dry.fixture.json") |> File.read!() |> Jason.decode!()
  @tokens @fixtures |> Path.join("tokens.fixture.json") |> File.read!() |> Jason.decode!()

  @deposit_address "0f2e39b5c1d3a4e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4"

  @doc "Installs this stand-in for the calling test, with `state` replacing part of it."
  @spec install(map()) :: :ok
  def install(state \\ %{}) do
    previous = Application.get_env(:autolaunch, :near_intents_client)
    Application.put_env(:autolaunch, :near_intents_client, __MODULE__)

    Application.put_env(
      :autolaunch,
      @key,
      Map.merge(
        %{
          asked: [],
          deadline_in: 3600,
          status: %{state: :pending_deposit, origin_tx: nil, destination_tx: nil}
        },
        state
      )
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:autolaunch, @key)

      if previous,
        do: Application.put_env(:autolaunch, :near_intents_client, previous),
        else: Application.delete_env(:autolaunch, :near_intents_client)
    end)
  end

  @doc "Replaces part of the scripted service, so a later read answers differently."
  @spec put(map()) :: :ok
  def put(changes), do: Application.put_env(:autolaunch, @key, Map.merge(state(), changes))

  @spec state() :: map()
  def state, do: Application.fetch_env!(:autolaunch, @key)

  @doc "The deposit address every quote that is not dry carries."
  def deposit_address, do: @deposit_address

  def tokens do
    {:ok,
     Enum.map(
       @tokens,
       &%{
         asset_id: &1["assetId"],
         symbol: &1["symbol"],
         blockchain: &1["blockchain"],
         decimals: &1["decimals"],
         price: &1["price"]
       }
     )}
  end

  # The request shape `RegentNearIntents.quote/1` takes; any other raises.
  def quote(
        %{usdc_amount: amount, recipient: "0x" <> _, refund_to: refund_to, dry: dry} = request
      )
      when is_integer(amount) and amount > 0 and is_binary(refund_to) and refund_to != "" and
             is_boolean(dry) do
    put(%{asked: [request | state().asked]})

    case state() do
      %{unavailable: true} ->
        {:error, %{reason: :http_error, message: "The 1Click service answered 503."}}

      _answering ->
        %{"quote" => quote} = @quote

        {:ok,
         %{
           amount_in: String.to_integer(quote["amountIn"]),
           amount_in_formatted: quote["amountInFormatted"],
           amount_out: String.to_integer(quote["amountOut"]),
           amount_out_formatted: quote["amountOutFormatted"],
           time_estimate_s: quote["timeEstimate"],
           deadline:
             DateTime.utc_now(:second)
             |> DateTime.add(state().deadline_in)
             |> DateTime.to_iso8601(),
           deposit_address: if(dry, do: nil, else: @deposit_address),
           raw: @quote
         }}
    end
  end

  def status(@deposit_address) do
    case state() do
      %{unavailable: true} ->
        {:error, %{reason: :http_error, message: "The 1Click service answered 503."}}

      %{status: status} ->
        {:ok, Map.put(status, :raw, %{})}
    end
  end
end
