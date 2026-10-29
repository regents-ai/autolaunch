defmodule Autolaunch.Exposure.Series do
  @moduledoc """
  The four Exposure operations every surface calls — the page, the HTTP routes
  and the browser tools — so each answers with the same figures and the same
  refusals:

    * `:list` — every series the site offers, as each stands now (public)
    * `:series` — one series with every price it has applied (public)
    * `:holdings` — what a wallet of the acting account holds of a series
    * `:prepare` — the wallet steps for one action, for a wallet of the acting account

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
         {:ok, holdings} <- Chain.holdings(series, wallet, block, opts) do
      {:ok, holdings |> Map.put(:series, read_at(series)) |> read_at()}
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
  end
end
