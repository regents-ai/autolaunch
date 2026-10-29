defmodule AutolaunchWeb.CapabilitiesTest do
  @moduledoc """
  The surfaces `priv/capabilities.json` gives each operation that its module
  cannot check when it compiles (`AutolaunchWeb.Capabilities`): an operation's
  `cli` surface is true exactly when regents-cli has its command in
  `cli/commands.json`.
  """
  use ExUnit.Case, async: true

  alias AutolaunchWeb.Capabilities

  @commands Path.expand("../../../cli/commands.json", __DIR__)

  test "an operation's cli surface is true exactly when regents-cli has its command" do
    commands = @commands |> File.read!() |> Jason.decode!() |> Map.fetch!("commands")

    named =
      for command <- commands,
          name <- [command["webmcp"], command["operation_id"]],
          name,
          into: MapSet.new(),
          do: name

    for %{"operation" => operation, "surfaces" => %{"cli" => cli}} <- Capabilities.operations() do
      assert cli == true == operation in named, operation
    end
  end
end
