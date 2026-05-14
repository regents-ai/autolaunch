defmodule Mix.Tasks.Autolaunch.GenerateSelectors do
  @moduledoc false

  use Mix.Task

  @shortdoc "Generates Elixir selector bindings from Foundry artifacts"

  @output_path "lib/autolaunch/contracts/generated_selectors.ex"

  @artifacts [
    {"AgentTokenVestingWallet",
     "contracts/out/AgentTokenVestingWallet.sol/AgentTokenVestingWallet.json"},
    {"LaunchDeploymentController",
     "contracts/out/LaunchDeploymentController.sol/LaunchDeploymentController.json"},
    {"LaunchFeeRegistry", "contracts/out/LaunchFeeRegistry.sol/LaunchFeeRegistry.json"},
    {"LaunchFeeVault", "contracts/out/LaunchFeeVault.sol/LaunchFeeVault.json"},
    {"LaunchPoolFeeHook", "contracts/out/LaunchPoolFeeHook.sol/LaunchPoolFeeHook.json"},
    {"DeferredAutolaunchFactory",
     "contracts/out/DeferredAutolaunchFactory.sol/DeferredAutolaunchFactory.json"},
    {"PaymentLinkFactory", "contracts/out/PaymentLinkFactory.sol/PaymentLinkFactory.json"},
    {"PaymentLinkReceiver", "contracts/out/PaymentLinkReceiver.sol/PaymentLinkReceiver.json"},
    {"PermissionlessExistingTokenRevenueFactory",
     "contracts/out/PermissionlessExistingTokenRevenueFactory.sol/PermissionlessExistingTokenRevenueFactory.json"},
    {"RegentLBPStrategy", "contracts/out/RegentLBPStrategy.sol/RegentLBPStrategy.json"},
    {"RegentRevenueStaking", "contracts/out/RegentRevenueStaking.sol/RegentRevenueStaking.json"},
    {"RevenueIngressAccount",
     "contracts/out/RevenueIngressAccount.sol/RevenueIngressAccount.json"},
    {"RevenueIngressFactory",
     "contracts/out/RevenueIngressFactory.sol/RevenueIngressFactory.json"},
    {"RevenueShareFactory", "contracts/out/RevenueShareFactory.sol/RevenueShareFactory.json"},
    {"RevenueShareSplitter", "contracts/out/RevenueShareSplitter.sol/RevenueShareSplitter.json"},
    {"RevenueShareSplitterV2",
     "contracts/out/RevenueShareSplitterV2.sol/RevenueShareSplitterV2.json"},
    {"SubjectRegistry", "contracts/out/SubjectRegistry.sol/SubjectRegistry.json"}
  ]

  @impl true
  def run(args) do
    check? = "--check" in args
    contents = generated_contents()

    if check? do
      check_current!(contents)
    else
      File.mkdir_p!(Path.dirname(@output_path))
      File.write!(@output_path, contents)
      Mix.shell().info("Generated #{@output_path}")
    end
  end

  defp check_current!(contents) do
    cond do
      !File.exists?(@output_path) ->
        Mix.raise("Generated selector file is missing. Run mix autolaunch.generate_selectors.")

      File.read!(@output_path) != contents ->
        Mix.raise("Generated selector file is stale. Run mix autolaunch.generate_selectors.")

      true ->
        Mix.shell().info("Generated selector file is current.")
    end
  end

  defp generated_contents do
    selectors_source =
      @artifacts
      |> Enum.map(fn {contract, path} -> contract_selectors_source(contract, path) end)
      |> Enum.join(",\n")

    source = """
    defmodule Autolaunch.Contracts.GeneratedSelectors do
      @moduledoc false

      @selectors %{
    #{selectors_source}
      }

      def selectors, do: @selectors
      def contracts, do: Map.keys(@selectors)

      def selector(contract, signature) do
        with {:ok, contract_selectors} <- Map.fetch(@selectors, contract),
             {:ok, selector} <- Map.fetch(contract_selectors, signature) do
          {:ok, selector}
        else
          :error -> {:error, :selector_not_found}
        end
      end

      def selector!(contract, signature) do
        @selectors
        |> Map.fetch!(contract)
        |> Map.fetch!(signature)
      end
    end
    """

    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp artifact_selectors(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("methodIdentifiers")
    |> Enum.map(fn {signature, selector} -> {signature, "0x" <> selector} end)
    |> Enum.sort()
  end

  defp contract_selectors_source(contract, path) do
    selector_lines =
      path
      |> artifact_selectors()
      |> Enum.map(fn {signature, selector} ->
        "      #{inspect(signature)} => #{inspect(selector)}"
      end)
      |> Enum.join(",\n")

    "    #{inspect(contract)} => %{\n#{selector_lines}\n    }"
  end
end
