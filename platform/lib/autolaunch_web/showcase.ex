defmodule AutolaunchWeb.Showcase do
  @moduledoc """
  The showcase setting and the gate on the motion lab at `/animations`.

  The setting (`:showcase`, from `AUTOLAUNCH_SHOWCASE` in `config/runtime.exs`) is
  `:public`, where the motion lab is open, or `:off`, where it does not exist. A
  request the gate refuses answers the site's own 404; a connected mount it
  refuses goes to the home page.
  """
  @doc "The showcase setting."
  def mode, do: Application.fetch_env!(:autolaunch, :showcase)

  @doc "The router's gate: the request goes on, or answers the site's 404."
  def admit(conn, :motion_lab) do
    mode() == :public or raise AutolaunchWeb.NotFoundError
    conn
  end

  def on_mount(:motion_lab, _params, _session, socket) do
    if mode() == :public,
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end
end
