defmodule Autolaunch.Exposure.Series do
  @moduledoc """
  The Exposure operations every surface calls — the page, the portfolio, the
  HTTP routes and the browser tools — so each answers with the same figures
  and the same refusals. A week is named by the factory's week number.

    * `:list` — the current week and the last eight open weeks before it, as
      each stands now (public)
    * `:week` — one week with every price its series has applied; nil is the
      current week (public)
    * `:holdings` — what a wallet of the acting account holds for one week
    * `:portfolio` — what a wallet of the acting account holds of each listed
      week, leaving out the weeks it holds nothing of
    * `:prepare` — the wallet steps for one action on one week, for a wallet
      of the acting account

  Nothing is stored: the contracts are the record. The acting account comes
  from the actor the caller authenticated; a wallet named in the request is
  only ever one of that account's own.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.Exposure,
    authorizers: [Ash.Policy.Authorizer]

  alias Autolaunch.CoveredCalls.Signer
  alias Autolaunch.Exposure.{Chain, Deployment, Steps}

  actions do
    action :list, :map do
      run fn _input, _context -> __MODULE__.refused(__MODULE__.list()) end
    end

    action :week, :map do
      argument :week, :integer, constraints: [min: 1]

      run fn input, _context ->
        input.arguments[:week] |> __MODULE__.read() |> __MODULE__.refused()
      end
    end

    action :holdings, :map do
      argument :week, :integer, allow_nil?: false, constraints: [min: 1]
      argument :wallet, :string

      run fn input, %{actor: actor} ->
        with {:ok, wallet} <- Signer.wallet(actor, input.arguments[:wallet]) do
          __MODULE__.holdings(input.arguments.week, wallet)
        end
        |> __MODULE__.refused()
      end
    end

    action :portfolio, {:array, :map} do
      argument :wallet, :string

      run fn input, %{actor: actor} ->
        with {:ok, wallet} <- Signer.wallet(actor, input.arguments[:wallet]) do
          __MODULE__.portfolio(wallet)
        end
        |> __MODULE__.refused()
      end
    end

    action :prepare, :map do
      argument :week, :integer, allow_nil?: false, constraints: [min: 1]
      argument :kind, :atom, allow_nil?: false, constraints: [one_of: Steps.kinds()]
      argument :signer, :string
      argument :leg, :atom, constraints: [one_of: [:overnight, :session]]
      argument :amount, :integer, constraints: [min: 1]
      argument :overnight, :integer, constraints: [min: 0]
      argument :session, :integer, constraints: [min: 0]

      run fn input, %{actor: actor} ->
        with {:ok, signer} <- Signer.wallet(actor, input.arguments[:signer]),
             {:ok, prepared} <- input.arguments |> Map.drop([:signer]) |> Steps.prepare(signer) do
          {:ok, Map.put(prepared, :signer, signer)}
        end
        |> __MODULE__.refused()
      end
    end
  end

  @doc false
  def list do
    with {:ok, config} <- Deployment.current(),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, factory} <- Chain.factory(config, block, opts),
         {:ok, weeks} <- Chain.listed(config, factory, block, opts) do
      {:ok,
       read_at(%{
         factory: factory.address,
         current_week: factory.current,
         paused: factory.paused,
         weeks: Enum.map(weeks, &read_at/1)
       })}
    end
  end

  @doc false
  def read(week) do
    with {:ok, config} <- Deployment.current(),
         {:ok, reading, block, opts} <- Chain.read_week(config, week),
         {:ok, reading} <- Chain.prints(reading, block, opts),
         do: {:ok, read_at(reading)}
  end

  @doc false
  def holdings(week, wallet) do
    with {:ok, config} <- Deployment.current(),
         {:ok, reading, block, opts} <- Chain.read_week(config, week),
         {:ok, holding} <- Chain.holding(reading, config, wallet, block, opts),
         do: {:ok, holding |> Map.put(:week, read_at(reading)) |> read_at()}
  end

  @doc false
  def portfolio(wallet) do
    with {:ok, config} <- Deployment.current(),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, factory} <- Chain.factory(config, block, opts),
         {:ok, weeks} <- Chain.listed(config, factory, block, opts),
         {:ok, held} <- Chain.holdings(weeks, wallet, block, opts),
         do: {:ok, Enum.map(held, &Map.update!(&1, :week, fn week -> read_at(week) end))}
  end

  defp read_at(reading), do: Map.put(reading, :read_at, DateTime.utc_now())

  # Ash turns a bare `{:error, atom}` into text, so a refusal is handed over as
  # an error that keeps its atom for `Autolaunch.Exposure.reason/1`.
  @doc false
  def refused({:error, reason}) when is_atom(reason),
    do: {:error, Ash.Error.Unknown.UnknownError.exception(error: reason)}

  def refused(result), do: result

  policies do
    policy action([:list, :week]) do
      authorize_if always()
    end

    policy action([:holdings, :portfolio, :prepare]) do
      authorize_if actor_present()
    end
  end
end
