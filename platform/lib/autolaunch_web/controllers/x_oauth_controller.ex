defmodule AutolaunchWeb.XOAuthController do
  @moduledoc false
  use AutolaunchWeb, :controller

  alias Autolaunch.Accounts.{SessionAuthority, XOAuth}

  def create(conn, %{"role" => role} = params) do
    case XOAuth.begin(claim(conn), role, params) do
      {:ok, payload} -> conn |> no_store() |> json(payload)
      {:error, :x_oauth_disabled} -> error(conn, :service_unavailable, "x_oauth_disabled")
      {:error, :invalid_role} -> error(conn, :unprocessable_entity, "invalid_role")
      {:error, :invalid_intent} -> error(conn, :unprocessable_entity, "invalid_intent")
      {:error, :stale_intent} -> error(conn, :conflict, "stale_intent")
      {:error, :stale_authority} -> error(conn, :conflict, "stale_authority")
      {:error, _reason} -> error(conn, :bad_gateway, "x_oauth_unavailable")
    end
  end

  def delete(conn, %{"role" => role} = params) do
    case XOAuth.disconnect(claim(conn), role, params) do
      {:ok, payload} -> conn |> no_store() |> json(Map.put(payload, :ok, true))
      {:error, :invalid_role} -> error(conn, :unprocessable_entity, "invalid_role")
      {:error, :invalid_intent} -> error(conn, :unprocessable_entity, "invalid_intent")
      {:error, :stale_intent} -> error(conn, :conflict, "stale_intent")
      {:error, :stale_authority} -> error(conn, :conflict, "stale_authority")
      {:error, _reason} -> error(conn, :unprocessable_entity, "disconnect_failed")
    end
  end

  def cancel(conn, %{"role" => role} = params) do
    case XOAuth.cancel(claim(conn), role, params) do
      {:ok, payload} -> conn |> no_store() |> json(Map.put(payload, :ok, true))
      {:error, :invalid_role} -> error(conn, :unprocessable_entity, "invalid_role")
      {:error, :invalid_intent} -> error(conn, :unprocessable_entity, "invalid_intent")
      {:error, :stale_intent} -> error(conn, :conflict, "stale_intent")
      {:error, :stale_authority} -> error(conn, :conflict, "stale_authority")
      {:error, _reason} -> error(conn, :unprocessable_entity, "cancel_failed")
    end
  end

  def callback(conn, params) do
    result =
      case XOAuth.callback(claim(conn), params) do
        {:ok, payload} -> Map.merge(payload, %{status: "connected"})
        {:error, _reason, payload} -> Map.merge(payload, %{status: "failed"})
        {:error, _reason} -> %{role: nil, generation: nil, status: "failed"}
      end

    conn
    |> no_store()
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'self' 'unsafe-inline'; font-src 'self'"
    )
    |> put_root_layout(false)
    |> render(:callback,
      origin: XOAuth.origin(),
      status: result.status,
      role: result.role,
      generation: result.generation
    )
  end

  defp claim(conn), do: conn |> get_session() |> SessionAuthority.claim()

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  defp error(conn, status, code),
    do: conn |> no_store() |> put_status(status) |> json(%{error: code})
end

defmodule AutolaunchWeb.XOAuthHTML do
  @moduledoc false

  use AutolaunchWeb, :html

  def callback(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en" data-brand="autolaunch" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width" />
        <title>X connection</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/js/app.css"} />
        <script>
          ((query) => {
            const follow = () =>
              document.documentElement.setAttribute("data-theme", query.matches ? "light" : "dark")
            follow()
            query.addEventListener("change", follow)
          })(window.matchMedia("(prefers-color-scheme: light)"))
        </script>
      </head>
      <body class="x-oauth-result">
        <Regent.Structure.frame class="x-oauth-sheet">
          <Regent.Structure.row rail={false}>
            <Regent.Structure.panel class="rg-inset">
              <main
                id="x-oauth-result"
                data-origin={@origin}
                data-status={@status}
                data-role={@role || ""}
                data-generation={@generation || ""}
              >
                <h1>X connection</h1>
                <p>
                  {if @status == "connected",
                    do: "X account connected.",
                    else: "X connection could not be completed."}
                </p>
                <p>
                  <a href="/" class="rg-button rg-button--primary"><span class="rg-button__label">Back to Autolaunch</span></a>
                </p>
              </main>
            </Regent.Structure.panel>
          </Regent.Structure.row>
        </Regent.Structure.frame>
        <script>
          (() => {
            const result = document.getElementById("x-oauth-result");
            const value = (key) => result.dataset[key] || null;
            const message = {
              source: "autolaunch-x-oauth",
              status: value("status"),
              role: value("role"),
              generation: value("generation")
            };
            if (window.opener) window.opener.postMessage(message, result.dataset.origin);
          })();
        </script>
      </body>
    </html>
    """
  end
end
