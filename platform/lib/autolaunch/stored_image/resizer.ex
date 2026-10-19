defmodule Autolaunch.StoredImage.Resizer do
  @moduledoc """
  Makes the sized copies of stored images one at a time. A large image can
  take over a hundred megabytes to decode, so however many copies are asked
  for at once, only one is being made. Each request carries the moment its
  caller stops waiting; a request whose turn comes after that is skipped.
  """

  use GenServer

  alias Vix.Vips.Operation

  @quality 80
  @timeout :timer.seconds(10)

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  A WebP square `width` pixels wide cut from the centre of `bytes`, never
  enlarged, keeping only the colour profile; `:error` when it cannot be made
  within ten seconds.
  """
  @spec webp(binary(), pos_integer()) :: {:ok, binary()} | :error
  def webp(bytes, width) do
    deadline = System.monotonic_time(:millisecond) + @timeout
    GenServer.call(__MODULE__, {:webp, bytes, width, deadline}, @timeout)
  catch
    :exit, _reason -> :error
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:webp, bytes, width, deadline}, _from, state) do
    if System.monotonic_time(:millisecond) < deadline do
      {:reply, resize(bytes, width), state}
    else
      {:reply, :error, state}
    end
  end

  defp resize(bytes, width) do
    with {:ok, image} <-
           Operation.thumbnail_buffer(bytes, width,
             height: width,
             crop: :VIPS_INTERESTING_CENTRE,
             size: :VIPS_SIZE_DOWN
           ),
         {:ok, webp} <-
           Operation.webpsave_buffer(image, Q: @quality, keep: [:VIPS_FOREIGN_KEEP_ICC]) do
      {:ok, webp}
    else
      _failed -> :error
    end
  end
end
