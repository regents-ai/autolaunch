defmodule Autolaunch.Lab do
  @moduledoc """
  The Base deployment description: `site-config.json` as the lab controller
  writes it at deployment, and as the contracts thread writes it for Base
  mainnet. One shape in every environment: the chain id, the site's RPC door,
  the door wallets use, every address the site prepares against and every ABI
  it encodes with.

  `AUTOLAUNCH_BASE_DEPLOYMENT` names the file and `AUTOLAUNCH_BASE_DEPLOYMENT_ID`
  labels the deployment; the label travels in every envelope's binding so a
  review made against one deployment never confirms against another. Chain
  31337 is a test chain (a local lab or a hosted fork carrying test assets);
  `test_chain?/0` is what the lab-only features key off.
  """

  alias Autolaunch.Chain.Address
  alias Autolaunch.LabRpcUrl

  @test_chain_id 31_337
  # 1 / 2^96 = 5^96 / 10^96, so a Q96 price is an exact 96-place decimal.
  @five_pow_96 Integer.pow(5, 96)
  @address_keys ~w(
    cca_factory
    escrow_implementation
    factory
    governance_safe
    hook
    permit2
    pool_manager
    position_manager
    receiver_implementation
    regent
    splitter_implementation
    strategy
    uerc20_factory
  )
  @abi_keys ~w(auction escrow factory hook permit2 receiver splitter strategy token)
  # The log ledger follows the factory from the block it was deployed in.
  @ledger_keys ~w(factory)

  @type t :: %{
          path: String.t(),
          run_id: String.t(),
          rpc_url: String.t(),
          public_rpc_url: String.t(),
          chain_id: pos_integer(),
          addresses: %{required(String.t()) => String.t()},
          abis: %{required(String.t()) => [map()]},
          start_blocks: %{required(String.t()) => non_neg_integer()}
        }

  @doc "Whether this site was given a Base deployment description."
  def configured?, do: is_binary(Application.get_env(:autolaunch, :autolaunch_base_deployment))

  @doc "Whether the Base deployment is a test chain: test assets with no mainnet value."
  def test_chain?, do: chain_id() == @test_chain_id

  @doc "Whether a reviewed chain id is the test chain's."
  def test_chain?(chain_id), do: chain_id == @test_chain_id

  @doc "The network a reviewed chain id names, as every Base page shows it."
  def network_name(chain_id) do
    if test_chain?(chain_id),
      do: "#{Autolaunch.ChainMode.label()} · chain #{@test_chain_id}",
      else: "Base"
  end

  @doc "The configured Base deployment's chain id, or `nil` without one."
  def chain_id, do: Application.get_env(:autolaunch, :autolaunch_base_chain_id)

  def current do
    with path when is_binary(path) <-
           Application.get_env(:autolaunch, :autolaunch_base_deployment),
         {:ok, config} <- load(path),
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
  Reads and validates `site-config.json`.

  `rpc_url` is the site's own door (`Autolaunch.LabRpcUrl.admitted/1`);
  `public_rpc_url` is the door wallets use (`Autolaunch.LabRpcUrl.public/2`).
  `start_blocks` names the block each watched contract was deployed in, by
  the same name as its address; the log ledger follows the factory from
  there. A test chain keeps the ledger off and names no start blocks.
  """
  def load(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         # Founder-supplied startup input; this path never comes from an HTTP request.
         # sobelow_skip ["Traversal.FileModule"]
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, rpc_url} <- LabRpcUrl.admitted(decoded["rpc_url"]),
         {:ok, public_rpc_url} <- LabRpcUrl.public(decoded["public_rpc_url"], rpc_url),
         {:ok, chain_id} <- chain_id(decoded["chain_id"]),
         {:ok, addresses} <- exact_addresses(decoded["addresses"]),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- Autolaunch.LabAbi.validate(abis),
         {:ok, start_blocks} <- start_blocks(decoded["start_blocks"], chain_id) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         public_rpc_url: public_rpc_url,
         chain_id: chain_id,
         addresses: addresses,
         abis: abis,
         start_blocks: start_blocks
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
  The binding an envelope carries to the browser. Its `rpc_url` is the public
  door, the one a wallet uses for the chain; the site's own `rpc_url` never
  leaves the server.
  """
  def binding(
        %{
          run_id: run_id,
          public_rpc_url: public_rpc_url,
          chain_id: chain_id,
          addresses: addresses
        },
        keys
      )
      when is_list(keys) do
    %{
      "run_id" => run_id,
      "rpc_url" => public_rpc_url,
      "chain_id" => chain_id,
      "addresses" => Map.take(addresses, Enum.map(keys, &to_string/1))
    }
  end

  def full_binding(%{run_id: run_id} = config) do
    %{
      run_id: run_id,
      path: config.path,
      rpc_url: config.rpc_url,
      public_rpc_url: config.public_rpc_url,
      chain_id: config.chain_id,
      addresses: config.addresses,
      abis: config.abis
    }
  end

  def binding_matches?(binding, keys) when is_map(binding) and is_list(keys) do
    case current() do
      {:ok, config} -> binding(config, keys) == stringify(binding)
      {:error, _reason} -> false
    end
  end

  @doc "The exact decimal a Q96 fixed-point price names: `q96 / 2^96`, with no rounding."
  def price_decimal(q96) when is_integer(q96) and q96 >= 0, do: plain(q96 * @five_pow_96, -96)

  # Drops trailing zeros by hand: `Decimal.normalize/1` would round the
  # coefficient to the context precision, and a Q96 price has more digits.
  defp plain(0, _exp), do: Decimal.new(0)
  defp plain(coef, exp) when rem(coef, 10) == 0, do: plain(div(coef, 10), exp + 1)
  defp plain(coef, exp), do: Decimal.new(1, coef, exp)

  @doc "`price_decimal/1` as the plain decimal string the site stores and shows."
  def format_price(q96), do: q96 |> price_decimal() |> Decimal.to_string(:normal)

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))
  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))

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

  # Named like the addresses, a nonnegative block each, the factory always.
  defp start_blocks(_blocks, @test_chain_id), do: {:ok, %{}}

  defp start_blocks(blocks, _chain_id) when is_map(blocks) do
    with [] <- Map.keys(blocks) -- @address_keys,
         [] <- @ledger_keys -- Map.keys(blocks),
         true <- Enum.all?(blocks, fn {_key, block} -> is_integer(block) and block >= 0 end) do
      {:ok, blocks}
    else
      _ -> {:error, :invalid_start_blocks}
    end
  end

  defp start_blocks(_blocks, _chain_id), do: {:error, :invalid_start_blocks}

  defp valid_address?(value), do: match?({:ok, _address}, Address.normalize(value))

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  defp stringify(value), do: value
end
