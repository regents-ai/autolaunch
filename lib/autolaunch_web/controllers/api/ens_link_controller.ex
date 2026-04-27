defmodule AutolaunchWeb.Api.EnsLinkController do
  use AutolaunchWeb, :controller

  alias Autolaunch.EnsLink
  alias AutolaunchWeb.ApiErrorTranslator

  import AutolaunchWeb.Api.ControllerHelpers

  def plan(conn, params) do
    render_result(conn, EnsLink.plan_link(conn.assigns[:current_human], params), :plan)
  end

  def prepare_ensip25(conn, params) do
    render_result(
      conn,
      EnsLink.prepare_ensip25_update(conn.assigns[:current_human], params),
      :prepared
    )
  end

  def prepare_erc8004(conn, params) do
    render_result(
      conn,
      EnsLink.prepare_erc8004_update(conn.assigns[:current_human], params),
      :prepared
    )
  end

  def prepare_bidirectional(conn, params) do
    render_result(
      conn,
      EnsLink.prepare_bidirectional_link(conn.assigns[:current_human], params),
      :prepared
    )
  end

  defp render_result(conn, result, root_key),
    do:
      render_api_result(conn, result, &ApiErrorTranslator.translate(:ens_link, &1),
        root_key: root_key
      )
end
