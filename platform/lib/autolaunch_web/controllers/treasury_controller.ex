defmodule AutolaunchWeb.TreasuryController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.TreasurySecurity
  alias AutolaunchWeb.ApiError

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
    do: ApiError.send(conn, :bad_request, "invalid_request", "The treasury address is invalid.")

  defp not_found(conn),
    do: ApiError.send(conn, :not_found, "not_found", "Treasury report not found.")

  defp internal_error(conn),
    do:
      ApiError.send(
        conn,
        :internal_server_error,
        "internal_error",
        "The request could not be completed."
      )
end
