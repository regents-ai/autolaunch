defmodule Autolaunch.Lab do
  @moduledoc """
  The Base deployment description: `site-config.json` as the lab controller
  writes it at deployment, and as the contracts thread writes it for Base
  mainnet. One shape in every environment: the chain id, the site's RPC door,
  the door wallets use, every address the site prepares against and every ABI
  it encodes with.

  `AUTOLAUNCH_BASE_DEPLOYMENT` names the file and `AUTOLAUNCH_BASE_DEPLOYMENT_ID`
  labels the deployment; the Stocks admission scan
  (`Autolaunch.Stocks.AdmissionScan`) reads a changed label as a new
  deployment and starts over. Chain
  31337 is a test chain, a local lab's Base fork carrying test assets;
  `test_chain?/0` is what the lab-only features key off.

  The top level names version 3's Revstake factory, strategy, hook and LP
  locker, which new launches go to. A chain with launches on version 2 has a
  `v2` section naming version 2's four, with their ABIs, for those launches;
  both versions share the escrow, splitter and payment receiver
  implementations and the UERC20 factory. A launch reads only the contracts
  of its own version (`contracts/2`).
  """

  alias Autolaunch.LabRpcUrl
  alias RegentChain.Address

  @test_chain_id 31_337
  # 1 / 2^96 = 5^96 / 10^96, so a Q96 price is an exact 96-place decimal.
  @five_pow_96 Integer.pow(5, 96)
  @address_keys ~w(
    cca_factory
    escrow_implementation
    factory
    governance_safe
    hook
    lp_locker
    permit2
    pool_manager
    position_manager
    receiver_implementation
    regent
    splitter_implementation
    strategy
    uerc20_factory
  )
  @abi_keys ~w(auction escrow factory hook lp_locker permit2 receiver splitter strategy token)
  # The contracts each Revstake version has of its own.
  @version_keys ~w(factory hook lp_locker strategy)

  @type version :: :v2 | :v3

  @type t :: %{
          path: String.t(),
          run_id: String.t(),
          rpc_url: String.t(),
          public_rpc_url: String.t(),
          chain_id: pos_integer(),
          version: version(),
          addresses: %{required(String.t()) => String.t()},
          abis: %{required(String.t()) => [map()]},
          v2: %{addresses: map(), abis: map()} | nil
        }

  @doc "Whether this site was given a Base deployment description."
  def configured?, do: is_binary(Application.get_env(:autolaunch, :autolaunch_base_deployment))

  @doc "Whether the Base deployment is a test chain: test assets with no mainnet value."
  def test_chain?, do: chain_id() == @test_chain_id

  @doc "Whether a reviewed chain id is the test chain's."
  def test_chain?(chain_id), do: chain_id == @test_chain_id

  @doc "The test chain's name, as every page of a lab site shows it."
  def label, do: "Local Base fork"

  @doc "The network a reviewed chain id names, as every Base page shows it."
  def network_name(chain_id) do
    if test_chain?(chain_id),
      do: "#{label()} · chain #{@test_chain_id}",
      else: "Base"
  end

  @doc "The configured Base deployment's chain id, or `nil` without one."
  def chain_id, do: Application.get_env(:autolaunch, :autolaunch_base_chain_id)

  def current do
    with path when is_binary(path) <-
           Application.get_env(:autolaunch, :autolaunch_base_deployment),
         {:ok, config} <- loaded(__MODULE__, path),
         run_id when is_binary(run_id) and run_id != "" <-
           Application.get_env(:autolaunch, :autolaunch_base_deployment_id) do
      {:ok, Map.put(config, :run_id, run_id)}
    else
      nil -> {:error, :deployment_missing}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :missing_deployment_id}
    end
  end

  def current! do
    case current() do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch Base deployment description is unavailable: #{reason}"
    end
  end

  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch Base deployment description is invalid: #{reason}"
    end
  end

  @doc """
  The description at `path` as `module.load/1` reads it, read from disk once
  for the life of the running site. A deployment's files are written before
  the site starts and a new deployment restarts it, so every later call is
  answered from memory. A description that does not load is not kept.
  """
  def loaded(module, path) do
    key = {module, path}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, config} <- module.load(path) do
          :persistent_term.put(key, config)
          {:ok, config}
        end

      config ->
        {:ok, config}
    end
  end

  @doc """
  Reads and validates `site-config.json`.

  `rpc_url` is the site's own door (`Autolaunch.LabRpcUrl.admitted/1`);
  `public_rpc_url` is the door wallets use (`Autolaunch.LabRpcUrl.public/2`).
  """
  # Founder-supplied startup input; this path never comes from an HTTP request.
  # sobelow_skip ["Traversal.FileModule"]
  def load(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, rpc_url} <- LabRpcUrl.admitted(decoded["rpc_url"]),
         {:ok, public_rpc_url} <- LabRpcUrl.public(decoded["public_rpc_url"], rpc_url),
         {:ok, chain_id} <- chain_id(decoded["chain_id"]),
         {:ok, addresses} <- exact_addresses(decoded["addresses"]),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- Autolaunch.LabAbi.validate(abis),
         {:ok, v2} <- v2_section(decoded["v2"]) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         public_rpc_url: public_rpc_url,
         chain_id: chain_id,
         version: :v3,
         addresses: addresses,
         abis: abis,
         v2: v2
       }}
    else
      false -> {:error, :absolute_path_required}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :enoent} -> {:error, :missing_file}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_shape}
    end
  end

  def load(_path), do: {:error, :absolute_path_required}

  @doc """
  The exact decimal a Q96 fixed-point price names, `q96 / 2^96` with no
  rounding, as the plain decimal string the site stores and shows.
  """
  def format_price(q96) when is_integer(q96) and q96 >= 0,
    do: (q96 * @five_pow_96) |> plain(-96) |> Decimal.to_string(:normal)

  # Drops trailing zeros by hand: `Decimal.normalize/1` would round the
  # coefficient to the context precision, and a Q96 price has more digits.
  defp plain(0, _exp), do: Decimal.new(0)
  defp plain(coef, exp) when rem(coef, 10) == 0, do: plain(div(coef, 10), exp + 1)
  defp plain(coef, exp), do: Decimal.new(1, coef, exp)

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))
  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))

  @doc """
  The deployment as a Revstake launch on `version` reads it: the description
  itself for a launch on the top level's version, or the description with
  version 2's factory, strategy, hook and LP locker in place of version 3's.
  """
  @spec contracts(t(), version()) :: {:ok, t()} | {:error, :contracts_missing}
  def contracts(%{version: version} = config, version), do: {:ok, config}

  def contracts(%{v2: %{} = v2} = config, :v2),
    do:
      {:ok,
       %{
         config
         | version: :v2,
           addresses: Map.merge(config.addresses, v2.addresses),
           abis: Map.merge(config.abis, v2.abis)
       }}

  def contracts(_config, _version), do: {:error, :contracts_missing}

  @doc "The RPC options for reads and calls against this deployment's chain."
  def rpc_opts(config, scope \\ "autolaunch local lab"), do: Autolaunch.LabRpc.opts(config, scope)

  @doc "The chain id a description names: any positive integer, exactly as written."
  def chain_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  def chain_id(_value), do: {:error, :invalid_chain_id}

  defp exact_addresses(addresses) when is_map(addresses) do
    with true <- Enum.sort(Map.keys(addresses)) == Enum.sort(@address_keys),
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end) do
      {:ok, Map.new(addresses, fn {key, value} -> {key, String.downcase(value)} end)}
    else
      _ -> {:error, :invalid_addresses}
    end
  end

  defp exact_addresses(_addresses), do: {:error, :invalid_addresses}

  defp exact_abis(abis) when is_map(abis) do
    with true <- Enum.sort(Map.keys(abis)) == Enum.sort(@abi_keys),
         true <- Enum.all?(abis, fn {_key, value} -> is_list(value) and value != [] end) do
      {:ok, abis}
    else
      _ -> {:error, :invalid_abis}
    end
  end

  defp exact_abis(_abis), do: {:error, :invalid_abis}

  defp v2_section(nil), do: {:ok, nil}

  defp v2_section(%{"addresses" => addresses, "abis" => abis} = section)
       when map_size(section) == 2 do
    with true <- is_map(addresses) and Enum.sort(Map.keys(addresses)) == @version_keys,
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end),
         true <- is_map(abis) and Enum.sort(Map.keys(abis)) == @version_keys,
         true <- Enum.all?(abis, fn {_key, value} -> is_list(value) and value != [] end),
         :ok <- Autolaunch.LabAbi.validate_v2(abis) do
      {:ok,
       %{
         addresses: Map.new(addresses, fn {key, value} -> {key, String.downcase(value)} end),
         abis: abis
       }}
    else
      _ -> {:error, :invalid_v2}
    end
  end

  defp v2_section(_section), do: {:error, :invalid_v2}

  defp valid_address?(value), do: match?({:ok, _address}, Address.normalize(value))
end
