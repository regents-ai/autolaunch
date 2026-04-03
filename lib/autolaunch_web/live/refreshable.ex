defmodule AutolaunchWeb.Live.Refreshable do
  @moduledoc false

  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]

  def schedule(socket, poll_ms) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, poll_ms)
    end

    socket
  end

  def refresh(socket, poll_ms, reload_fun) when is_function(reload_fun, 1) do
    socket
    |> schedule(poll_ms)
    |> reload_fun.()
  end

  def wallet_started(socket, message), do: put_flash(socket, :info, message)

  def wallet_registered(socket, message, reload_fun) when is_function(reload_fun, 1) do
    socket
    |> reload_fun.()
    |> put_flash(:info, message)
  end

  def wallet_error(socket, message), do: put_flash(socket, :error, message)
end
