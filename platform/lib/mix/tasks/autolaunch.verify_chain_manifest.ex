defmodule Mix.Tasks.Autolaunch.VerifyChainManifest do
  use Mix.Task

  @shortdoc "Verifies the site's pinned Base contracts through bounded read-only RPC calls"
  @timeout_ms 12_000
  @attempts 3

  @impl Mix.Task
  def run(args) do
    {opts, [], []} = OptionParser.parse(args, strict: [rpc_url: :string])

    # The endpoint the site itself is configured to read Base through, so the
    # evidence is verified against the same provider the running site trusts.
    rpc_url = opts[:rpc_url] || Application.fetch_env!(:autolaunch, :base_read_rpc_url)
    cast = find_cast!()
    root = File.cwd!()

    entries =
      root
      |> Path.join("contracts/chain-contracts.yaml")
      |> YamlElixir.read_from_file!()
      |> get_in(["contracts", Access.at(0), "reviewed_action_evidence"])

    assert_equal!(
      cast!(cast, ["chain-id", "--rpc-url", rpc_url], "Base chain id"),
      "8453",
      "Base chain id"
    )

    Mix.shell().info("Verifying the site's reviewed chain evidence...")
    Enum.each(entries, &verify_entry!(cast, rpc_url, root, &1))
    verify_regent_reads!(cast, rpc_url, entries)
    report_unpinned(entries)

    Mix.shell().info("Verified the site's chain evidence without sending a transaction.")
  end

  defp verify_entry!(cast, rpc_url, root, entry) do
    id = entry["contract_id"]
    abi_path = entry["abi_path"]
    address = entry["address"]

    if abi_path, do: verify_abi_digest!(root, id, abi_path, entry["abi_sha256"])

    case address do
      nil ->
        Mix.shell().info("  #{id}: unpinned, no address in the manifest")

      address ->
        Mix.shell().info("  #{id}: address #{address}")
        verify_pinned_runtime!(cast, rpc_url, id, entry)
        if abi_path, do: verify_abi_selectors!(cast, rpc_url, root, id, entry)
    end
  end

  defp verify_abi_digest!(root, id, abi_path, expected) do
    digest =
      root
      |> Path.join("contracts")
      |> Path.join(abi_path)
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert_equal!(digest, expected, "#{id} ABI SHA-256")
    Mix.shell().info("  #{id}: ABI #{abi_path} SHA-256 matches the manifest")
  end

  defp verify_pinned_runtime!(cast, rpc_url, id, entry) do
    case entry["runtime_code"] do
      nil ->
        Mix.shell().info("  #{id}: runtime code carries no pinned digest in the manifest")

      _pinned ->
        verify_runtime!(cast, rpc_url, id, entry)

        Mix.shell().info(
          "  #{id}: runtime byte length, SHA-256 and Keccak-256 match the manifest"
        )
    end
  end

  defp verify_regent_reads!(cast, rpc_url, entries) do
    by_id = Map.new(entries, &{&1["contract_id"], &1})
    regent = by_id["regent_erc20"]["address"]
    staking = by_id["regent_revenue_staking"]["address"]
    expected_usdc = get_in(by_id, ["regent_revenue_staking", "onchain_constants", "usdc"])

    assert_equal!(call_one!(cast, rpc_url, regent, "symbol()(string)"), "REGENT", "REGENT symbol")
    Mix.shell().info("  regent_erc20: symbol() is REGENT")

    decimals =
      call_one!(cast, rpc_url, regent, "decimals()(uint8)") |> integer_value!("REGENT decimals")

    Mix.shell().info("  regent_erc20: decimals() is #{decimals}")

    stake_token = call_one!(cast, rpc_url, staking, "stakeToken()(address)")
    assert_address!(stake_token, regent, "staked REGENT token")

    Mix.shell().info(
      "  regent_revenue_staking: stakeToken() is #{stake_token}, the manifest REGENT is #{regent}"
    )

    usdc = call_one!(cast, rpc_url, staking, "usdc()(address)")
    assert_address!(usdc, expected_usdc, "staking USDC")

    Mix.shell().info(
      "  regent_revenue_staking: usdc() is #{usdc}, the manifest USDC is #{expected_usdc}"
    )

    total_staked =
      call_one!(cast, rpc_url, staking, "totalStaked()(uint256)")
      |> integer_value!("totalStaked()")

    unless total_staked >= 0, do: Mix.raise("totalStaked() returned a negative value")
    Mix.shell().info("  regent_revenue_staking: totalStaked() is #{total_staked}")
  end

  defp report_unpinned(entries) do
    case Enum.filter(entries, &is_nil(&1["address"])) do
      [] ->
        Mix.shell().info("Every reviewed evidence entry carries an address.")

      unpinned ->
        names = Enum.map_join(unpinned, ", ", & &1["contract_id"])
        Mix.shell().info("Unpinned entries, verified against no deployment: #{names}")
    end
  end

  defp verify_runtime!(cast, rpc_url, id, contract) do
    code = cast!(cast, ["code", contract["address"], "--rpc-url", rpc_url], "#{id} runtime")

    if code == "0x" do
      Mix.raise("#{id} has no deployed runtime code")
    end

    bytes = code |> String.trim_leading("0x") |> Base.decode16!(case: :mixed)
    expected = contract["runtime_code"]

    assert_equal!(byte_size(bytes), expected["bytes"], "#{id} runtime byte length")

    sha256 = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert_equal!(sha256, expected["sha256"], "#{id} runtime SHA-256")

    keccak = cast!(cast, ["keccak", code], "#{id} runtime Keccak-256")
    assert_equal!(String.downcase(keccak), expected["keccak256"], "#{id} runtime Keccak-256")
  end

  defp verify_abi_selectors!(cast, rpc_url, root, id, contract) do
    code = cast!(cast, ["code", contract["address"], "--rpc-url", rpc_url], "#{id} selectors")

    runtime_selectors =
      cast!(cast, ["selectors", code], "#{id} selectors")
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split() |> hd() |> String.downcase() end)
      |> MapSet.new()

    abi_selectors =
      root
      |> Path.join("contracts")
      |> Path.join(contract["abi_path"])
      |> read_json!()
      |> Enum.filter(&(&1["type"] == "function"))
      |> Enum.map(fn item ->
        signature = canonical_signature(item)
        cast!(cast, ["sig", signature], "#{id} ABI selector")
      end)
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    # The pinned ABI is the reviewed consumer surface, never the whole contract,
    # so the deployment has to declare every selector it pins and may declare
    # more.
    unless MapSet.subset?(abi_selectors, runtime_selectors) do
      missing = abi_selectors |> MapSet.difference(runtime_selectors) |> Enum.sort()
      Mix.raise("#{id} deployment is missing pinned selectors: #{Enum.join(missing, ", ")}")
    end

    Mix.shell().info(
      "  #{id}: the deployment declares all #{MapSet.size(abi_selectors)} pinned selectors"
    )
  end

  @doc false
  def canonical_signature(%{"name" => name, "inputs" => inputs}) do
    types = Enum.map_join(inputs, ",", &canonical_abi_type/1)
    "#{name}(#{types})"
  end

  defp canonical_abi_type(%{"type" => "tuple" <> suffix, "components" => components}) do
    "(#{Enum.map_join(components, ",", &canonical_abi_type/1)})#{suffix}"
  end

  defp canonical_abi_type(%{"type" => type}), do: type

  defp call_one!(cast, rpc_url, address, signature) do
    args = ["call", address, signature, "--json", "--rpc-url", rpc_url]

    case cast!(cast, args, signature) |> Jason.decode!() do
      [value] -> value
      values -> Mix.raise("Unexpected result shape for #{signature}: #{length(values)} values")
    end
  end

  defp cast!(cast, args, label), do: cast_attempt(cast, args, label, 1)

  defp cast_attempt(cast, args, label, attempt) do
    task = Task.async(fn -> System.cmd(cast, args, stderr_to_stdout: true) end)

    result = Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {output, 0}} ->
        String.trim(output)

      {:ok, {output, _status}} when attempt < @attempts ->
        if transient_failure?(output) do
          Process.sleep(250 * attempt)
          cast_attempt(cast, args, label, attempt + 1)
        else
          Mix.raise("#{label} failed (provider details redacted)")
        end

      nil when attempt < @attempts ->
        Process.sleep(250 * attempt)
        cast_attempt(cast, args, label, attempt + 1)

      {:exit, _reason} when attempt < @attempts ->
        Process.sleep(250 * attempt)
        cast_attempt(cast, args, label, attempt + 1)

      _ ->
        Mix.raise(
          "#{label} failed after #{@attempts} bounded attempts (provider details redacted)"
        )
    end
  end

  defp transient_failure?(output) do
    normalized = String.downcase(output)

    Enum.any?(
      ["429", "rate limit", "timeout", "timed out", "connection", "temporarily"],
      &String.contains?(normalized, &1)
    )
  end

  defp find_cast! do
    [Path.join(System.user_home!(), ".foundry/bin/cast"), System.find_executable("cast")]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find(fn candidate ->
      File.regular?(candidate) and
        match?({"cast Version: 1.5.1-stable" <> _, 0}, System.cmd(candidate, ["--version"]))
    end)
    |> case do
      nil -> Mix.raise("Foundry cast 1.5.1-stable is required")
      cast -> cast
    end
  end

  defp integer_value!(value, _label) when is_integer(value), do: value

  defp integer_value!(value, label) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> Mix.raise("#{label} returned a non-integer value")
    end
  end

  defp integer_value!(_value, label), do: Mix.raise("#{label} returned a non-integer value")

  defp assert_address!(actual, expected, label) do
    assert_equal!(String.downcase(actual), String.downcase(expected), label)
  end

  defp assert_equal!(actual, expected, label) do
    unless actual == expected do
      Mix.raise("#{label} drifted: expected #{inspect(expected)}, got #{inspect(actual)}")
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
