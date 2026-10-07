defmodule AutolaunchWeb.ShareCard.Cache do
  @moduledoc """
  The finished share pictures, one per auction and one per token, each kept
  with the version of its figures it was drawn for (`AutolaunchWeb.ShareCard`).
  A request at a newer version draws the picture again and replaces the kept
  one, so the table never holds more than one picture per auction or token.
  The version is the server's own, never the `v` a request's address carries.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The picture kept for `key` at `version`, or the one `draw` makes, kept when it succeeds."
  @spec fetch(term(), String.t(), (-> {:ok, binary()} | {:error, term()})) ::
          {:ok, binary()} | {:error, term()}
  def fetch(key, version, draw) do
    case :ets.lookup(@table, key) do
      [{^key, ^version, png}] -> {:ok, png}
      _missing_or_older -> draw.() |> keep(key, version)
    end
  end

  defp keep({:ok, png} = drawn, key, version) do
    :ets.insert(@table, {key, version, png})
    drawn
  end

  defp keep(error, _key, _version), do: error

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
