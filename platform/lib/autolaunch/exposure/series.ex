defmodule Autolaunch.Exposure.Series do
  @moduledoc """
  The four Exposure operations every surface calls — the page, the HTTP routes
  and the browser tools — so each answers with the same figures and the same
  refusals:

    * `:list` — every series the site offers, as each stands now (public)
    * `:series` — one series with every price it has applied (public)
    * `:holdings` — what a wallet of the acting account holds of a series
    * `:prepare` — the wallet steps for one action, for a wallet of the acting account

  The hosted MCP tools run the reads and step preparation as answer actions:
  the same operation, answered with the `data` of the
  document its route sends (`AutolaunchWeb.ExposureAnswer.answer/2`), only
  while the site offers Exposure and never for a connected app calling as
  itself. Holdings and preparation require a paired agent, and preparation
  also requires that prelaunch read-only mode has ended.

  Nothing is stored: the contracts are the record. The acting account comes
  from the actor the caller authenticated; a wallet named in the request is
  only ever one of that account's own.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.Exposure,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.Exposure
  alias Autolaunch.Exposure.{Chain, Deployment, Steps}
  alias AutolaunchWeb.{ApiError, ExposureAnswer}

  @series "The series contract's address on Base, 0x and 40 hex digits, as the site lists it."
  @uint256_max 2 ** 256 - 1

  actions do
    action :list, {:array, :map} do
      run fn _input, _context -> __MODULE__.refused(__MODULE__.list()) end
    end

    action :series, :map do
      argument :series, :string, allow_nil?: false

      run fn input, _context ->
        input.arguments.series |> __MODULE__.read() |> __MODULE__.refused()
      end
    end

    action :holdings, :map do
      argument :series, :string, allow_nil?: false
      argument :wallet, :string

      run fn input, %{actor: actor} ->
        with {:ok, wallet} <- Signer.wallet(actor, input.arguments[:wallet]) do
          __MODULE__.holdings(input.arguments.series, wallet)
        end
        |> __MODULE__.refused()
      end
    end

    action :prepare, :map do
      argument :series, :string, allow_nil?: false
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: Steps.kinds()]
      argument :signer, :string
      argument :leg, :atom, constraints: [one_of: [:overnight, :session]]
      argument :amount, :integer, constraints: [min: 1, max: @uint256_max]
      argument :overnight, :integer, constraints: [min: 0, max: @uint256_max]
      argument :session, :integer, constraints: [min: 0, max: @uint256_max]

      run fn input, %{actor: actor} ->
        with {:ok, signer} <- Signer.wallet(actor, input.arguments[:signer]),
             {:ok, prepared} <- input.arguments |> Map.drop([:signer]) |> Steps.prepare(signer) do
          {:ok, Map.put(prepared, :signer, signer)}
        end
        |> __MODULE__.refused()
      end
    end

    action :list_answer, {:array, :map} do
      run fn _input, %{actor: actor} ->
        [actor: actor]
        |> Autolaunch.Exposure.exposure_series_list()
        |> AutolaunchWeb.ExposureAnswer.answer(:list)
        |> AutolaunchWeb.ApiError.data()
      end
    end

    action :series_answer, :map do
      argument :series, :string,
        allow_nil?: false,
        constraints: [trim?: false]

      run fn input, %{actor: actor} ->
        input.arguments.series
        |> Autolaunch.Exposure.exposure_series(actor: actor)
        |> AutolaunchWeb.ExposureAnswer.answer(:series)
        |> AutolaunchWeb.ApiError.data()
      end
    end

    action :holdings_answer, :map do
      argument :series, :string,
        allow_nil?: false,
        constraints: [trim?: false]

      run fn input, %{actor: actor} ->
        input.arguments.series
        |> Autolaunch.Exposure.exposure_holdings(actor: actor)
        |> AutolaunchWeb.ExposureAnswer.answer(:holdings)
        |> AutolaunchWeb.ApiError.data()
      end
    end

    action :prepare_exposure_answer, :map do
      argument :series, :string,
        allow_nil?: false,
        constraints: [trim?: false],
        description: @series

      argument :kind, :atom, allow_nil?: false, constraints: [one_of: Steps.kinds()]

      argument :signer, :string,
        description: "One of my person's own wallets. Omit it to use their signed-in wallet."

      argument :leg, :atom,
        constraints: [one_of: [:overnight, :session]],
        description: "For a buy or sell, the overnight or session token."

      argument :amount, :integer,
        constraints: [min: 1, max: @uint256_max],
        description: "USDC micro-units for a buy, raw token units for a sell or mint."

      argument :overnight, :integer,
        constraints: [min: 0, max: @uint256_max],
        description: "For redeem, the raw After-hours units to return."

      argument :session, :integer,
        constraints: [min: 0, max: @uint256_max],
        description: "For redeem, the raw Market-hours units to return."

      run fn %{arguments: %{series: series, kind: kind} = arguments}, context ->
        series
        |> Exposure.prepare_exposure(
          kind,
          Map.drop(arguments, [:series, :kind]),
          Ash.Context.to_opts(context)
        )
        |> ExposureAnswer.answer(:prepare)
        |> ApiError.data()
      end
    end
  end

  @doc false
  def list do
    with {:ok, config} <- Deployment.current(),
         {:ok, block, opts} <- Chain.latest(config.lab),
         do: read_each(Enum.reverse(config.series), config, block, opts, [])
  end

  defp read_each([], _config, _block, _opts, kept), do: {:ok, Enum.reverse(kept)}

  defp read_each([address | rest], config, block, opts, kept) do
    with {:ok, series} <- Chain.series(address, config, block, opts),
         do: read_each(rest, config, block, opts, [read_at(series) | kept])
  end

  @doc false
  def read(address) do
    with {:ok, config} <- Deployment.current(),
         {:ok, address} <- Deployment.series(address),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, series} <- Chain.series(address, config, block, opts),
         do: {:ok, read_at(series)}
  end

  @doc false
  def holdings(address, wallet) do
    with {:ok, config} <- Deployment.current(),
         {:ok, address} <- Deployment.series(address),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, series} <- Chain.series(address, config, block, opts),
         {:ok, holdings} <- Chain.holdings(series, wallet, block, opts),
         {:ok, usdc} <- Chain.token_balance(config.usdc, wallet, block, opts) do
      {:ok, holdings |> Map.merge(%{usdc: usdc, series: read_at(series)}) |> read_at()}
    end
  end

  defp read_at(series), do: Map.put(series, :read_at, DateTime.utc_now())

  # Ash turns a bare `{:error, atom}` into text, so a refusal is handed over as
  # an error that keeps its atom for `Autolaunch.Exposure.reason/1`.
  @doc false
  def refused({:error, reason}) when is_atom(reason),
    do: {:error, Ash.Error.Unknown.UnknownError.exception(error: reason)}

  def refused(result), do: result

  policies do
    policy action([:list, :series]) do
      authorize_if always()
    end

    policy action([:holdings, :prepare]) do
      authorize_if actor_present()
    end

    # The hosted MCP tools: only while the site offers Exposure, and never for
    # an app connected to a person's account calling as itself (its token is
    # for its identity tools alone; paired, it calls as its agent instead).
    policy action([:list_answer, :series_answer, :holdings_answer, :prepare_exposure_answer]) do
      forbid_unless Autolaunch.Exposure.Checks.Offered
      forbid_if actor_attribute_equals(:role, :connected_app)
      authorize_if always()
    end

    policy action([:holdings_answer, :prepare_exposure_answer]) do
      authorize_if actor_attribute_equals(:role, :agent)
    end

    policy action(:prepare_exposure_answer) do
      authorize_if Autolaunch.CoveredCalls.Checks.LaunchesOpen
    end
  end
end
