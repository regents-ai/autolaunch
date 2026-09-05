defmodule AutolaunchWeb.TreasuryController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.TreasurySecurity

  def show(conn, %{"address" => address} = params) do
    autolaunch = conn.private[:treasury_controller_autolaunch] || Autolaunch

    with true <- Map.keys(params) == ["address"],
         {:ok, report} when not is_nil(report) <-
           autolaunch.current_treasury_security(address, actor: nil) do
      json(conn, %{data: TreasurySecurity.public_view(report)})
    else
      false -> invalid_request(conn)
      :error -> invalid_request(conn)
      {:ok, nil} -> not_found(conn)
      {:error, :invalid_address} -> invalid_request(conn)
      {:error, _error} -> internal_error(conn)
    end
  end

  defp invalid_request(conn),
    do:
      conn
      |> put_status(:bad_request)
      |> json(%{error: %{code: "invalid_request", message: "The treasury address is invalid."}})

  defp not_found(conn),
    do:
      conn
      |> put_status(:not_found)
      |> json(%{error: %{code: "not_found", message: "Treasury report not found."}})

  defp internal_error(conn),
    do:
      conn
      |> put_status(:internal_server_error)
      |> json(%{error: %{code: "internal_error", message: "The request could not be completed."}})
end
