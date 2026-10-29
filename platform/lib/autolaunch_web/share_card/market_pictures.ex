defmodule AutolaunchWeb.ShareCard.MarketPictures do
  @moduledoc """
  Draws the pictures of covered-call markets and After-hours Exposure series
  (`AutolaunchWeb.ShareCard.market_png/3`) one at a time. Each is drawn from
  the chain, so link previews asking at once, as they do when a picture's
  address moves on, wait for the one drawing in hand and are then answered
  from `AutolaunchWeb.ShareCard.Cache`. A picture that could not be drawn
  answers with that failure for 30 seconds before it is tried again.
  """

  use GenServer

  alias AutolaunchWeb.ShareCard.Cache

  @failed_ms 30_000
  @wait_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The picture for `key` at `version`, kept or drawn by `draw`, as `Cache.fetch/3` answers."
  @spec fetch(term(), String.t(), (-> {:ok, binary()} | {:error, term()})) ::
          {:ok, binary()} | {:error, term()}
  def fetch(key, version, draw),
    do: GenServer.call(__MODULE__, {:fetch, key, version, draw}, @wait_ms)

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({:fetch, key, version, draw}, _from, failed) do
    now = System.monotonic_time(:millisecond)

    case failed do
      %{^key => {^version, error, until}} when until > now ->
        {:reply, error, failed}

      _not_failed_lately ->
        case Cache.fetch(key, version, draw) do
          {:ok, _png} = drawn -> {:reply, drawn, Map.delete(failed, key)}
          error -> {:reply, error, Map.put(failed, key, {version, error, now + @failed_ms})}
        end
    end
  end
end
