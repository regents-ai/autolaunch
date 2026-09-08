defmodule AutolaunchWeb.Prelaunch do
  @moduledoc "Prelaunch HTTP and LiveView admission, before sessions, uploads or write-capable mounts."
  @behaviour Plug
  import Plug.Conn
  alias Autolaunch.Prelaunch

  @read_events %{
    AutolaunchWeb.HomeLive => ~w(search filter retry load-more),
    AutolaunchWeb.AuctionsLive => ~w(retry),
    AutolaunchWeb.TokensLive => ~w(retry),
    AutolaunchWeb.AuctionLive => ~w(retry),
    AutolaunchWeb.TokenLive => ~w(retry),
    AutolaunchWeb.PortfolioLive => ~w(refresh)
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Router path matching decodes segments; the admission check must do so too.
    path = Enum.map(conn.path_info, &URI.decode/1)

    cond do
      not Prelaunch.read_only?() -> conn
      match?(["create" | _], path) -> refuse(conn, 404)
      account_path?(path) -> refuse(conn, 503)
      conn.method in ["GET", "HEAD"] -> conn
      public_quote?(conn.method, path) -> conn
      true -> refuse(conn, 503)
    end
  end

  defp account_path?(["auth" | _]), do: true
  defp account_path?(["api", "v1", "profile" | _]), do: true
  defp account_path?(_), do: false

  # This existing POST only calculates a quote from stored public data.
  defp public_quote?("POST", ["api", "v1", "auctions", _id, "bid-quote"]), do: true
  defp public_quote?(_, _), do: false

  defp refuse(conn, status) do
    json? =
      match?(["api" | _], conn.path_info) or
        Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "application/json"))

    {type, body} =
      if json? do
        {"application/json",
         Jason.encode!(%{
           error: %{
             code: "prelaunch_read_only",
             message: "Autolaunch is read-only until contract deployment."
           }
         })}
      else
        {"text/html",
         AutolaunchWeb.ErrorHTML.render("#{status}.html", %{}) |> Phoenix.HTML.Safe.to_iodata()}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type(type)
    |> send_resp(status, if(conn.method == "HEAD", do: "", else: body))
    |> halt()
  end

  # An old signed LiveView token must not resurrect /create over the socket.
  # Write-capable LiveComponents are not mounted at all during prelaunch.
  def on_mount(:default, _params, _session, socket) do
    cond do
      not Prelaunch.read_only?() ->
        {:cont, socket}

      socket.view == AutolaunchWeb.CreateLive ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

      true ->
        {:cont,
         Phoenix.LiveView.attach_hook(socket, :prelaunch_read_only, :handle_event, fn event,
                                                                                      _params,
                                                                                      socket ->
           if event in Map.get(@read_events, socket.view, []),
             do: {:cont, socket},
             else: {:halt, socket}
         end)}
    end
  end
end
