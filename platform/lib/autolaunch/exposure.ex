defmodule Autolaunch.Exposure do
  @moduledoc """
  Exposure on Base stock tokens: one stock token split, for a fixed term, into
  an After-hours token that carries the stock's moves from each close to the
  next open and a Market-hours token that carries its moves from each open to
  the close. The series contract (`contracts/exposure`) is the record; see
  `platform/docs/after-hours-exposure-spec.md`.
  """

  use Ash.Domain, otp_app: :autolaunch, extensions: [AshAi]

  # The hosted MCP tools, each the browser tool of the same
  # name, with that tool's title and words from priv/exposure_tools.json, less
  # how a browser host signs (`AutolaunchWeb.Capabilities` checks their inputs).
  @tools_path Application.app_dir(:autolaunch, "priv/exposure_tools.json")
  @external_resource @tools_path
  @browser_signing [
    " Signed: your browser host signs it with your own agent key, as regents browser does.",
    " Browser sign-in is not agent authority."
  ]
  @browser_tools (for tool <-
                        @tools_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools"),
                      into: %{} do
                    words = String.replace(tool["description"], @browser_signing, "")
                    {tool["name"], %{tool | "description" => words}}
                  end)

  @doc "The refusal an operation answered with, as the atom its surfaces turn into words."
  def reason(%{errors: [%{error: reason} | _]}) when is_atom(reason), do: reason
  def reason(reason) when is_atom(reason), do: reason
  def reason(_error), do: :chain_unavailable

  tools do
    tool :autolaunch_after_hour_stocks_list, Autolaunch.Exposure.Series, :list_answer do
      title(@browser_tools["autolaunch_after_hour_stocks_list"]["title"])
      description @browser_tools["autolaunch_after_hour_stocks_list"]["description"]
      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :autolaunch_after_hour_stocks_series, Autolaunch.Exposure.Series, :series_answer do
      title(@browser_tools["autolaunch_after_hour_stocks_series"]["title"])
      description @browser_tools["autolaunch_after_hour_stocks_series"]["description"]
      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :autolaunch_my_after_hour_stocks, Autolaunch.Exposure.Series, :holdings_answer do
      title(@browser_tools["autolaunch_my_after_hour_stocks"]["title"])
      description @browser_tools["autolaunch_my_after_hour_stocks"]["description"]
      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end

    tool :autolaunch_after_hour_stocks_prepare,
         Autolaunch.Exposure.Series,
         :prepare_exposure_answer do
      title(@browser_tools["autolaunch_after_hour_stocks_prepare"]["title"])
      description @browser_tools["autolaunch_after_hour_stocks_prepare"]["description"]
      annotations(read_only_hint: true, idempotent_hint: true, open_world_hint: true)
    end
  end

  resources do
    resource Autolaunch.Exposure.Series do
      define :exposure_series_list, action: :list
      define :exposure_series, action: :series, args: [:series]
      define :exposure_holdings, action: :holdings, args: [:series]
      define :prepare_exposure, action: :prepare, args: [:series, :kind]
      define :prepare_exposure_answer, args: [:series, :kind]
    end
  end
end
