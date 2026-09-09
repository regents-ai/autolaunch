defmodule Autolaunch.LabTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Lab

  @moduletag :tmp_dir

  # Validation stops at the first refused key, so a configuration holding only
  # the RPC doors and the chain id proves which doors each mode admits: an
  # admitted pair reaches the address check (`:invalid_addresses`), a refused
  # one never does.
  test "fork mode alone admits private and https doors and requires the public door", %{
    tmp_dir: dir
  } do
    loopback = "http://127.0.0.1:8545"
    internal = "http://autolaunch-fork.internal:8545"
    https = "https://fork-admin.example.test/rpc"
    public = "https://fork.example.test"

    # Loopback with no public door: the lab shape, admitted in base mode.
    assert {:error, :invalid_addresses} = load(dir, %{"rpc_url" => loopback}, :base)

    # Base mode admits nothing but loopback for the site's own door.
    assert {:error, :rpc_not_admitted} = load(dir, %{"rpc_url" => internal}, :base)
    assert {:error, :rpc_not_admitted} = load(dir, %{"rpc_url" => https}, :base)

    # Fork mode admits the private network and https, and then requires the public door.
    assert {:error, :missing_public_rpc} = load(dir, %{"rpc_url" => internal}, :fork)
    assert {:error, :missing_public_rpc} = load(dir, %{"rpc_url" => https}, :fork)
    assert {:error, :missing_public_rpc} = load(dir, %{"rpc_url" => loopback}, :fork)

    assert {:error, :invalid_addresses} =
             load(dir, %{"rpc_url" => internal, "public_rpc_url" => public}, :fork)

    assert {:error, :invalid_addresses} =
             load(dir, %{"rpc_url" => https, "public_rpc_url" => public}, :fork)

    # Plain http outside loopback and the private network is never the site's door.
    assert {:error, :rpc_not_admitted} =
             load(
               dir,
               %{"rpc_url" => "http://fork.example.test:8545", "public_rpc_url" => public},
               :fork
             )

    # Neither door carries credentials, a query or a fragment.
    for own <- [
          "http://user:secret@autolaunch-fork.internal:8545",
          "http://autolaunch-fork.internal:8545?x=1",
          "https://fork-admin.example.test/rpc#x"
        ] do
      assert {:error, :rpc_not_admitted} =
               load(dir, %{"rpc_url" => own, "public_rpc_url" => public}, :fork)
    end

    # The public door is https and nothing else.
    for wallet_door <- [
          "http://fork.example.test",
          "http://127.0.0.1:8545",
          "https://user:secret@fork.example.test",
          "https://fork.example.test?x=1",
          ""
        ] do
      assert {:error, :invalid_public_rpc} =
               load(dir, %{"rpc_url" => internal, "public_rpc_url" => wallet_door}, :fork)
    end
  end

  test "the envelope binding names the public door, never the site's own" do
    config = %{
      run_id: "preview",
      rpc_url: "http://autolaunch-fork.internal:8545",
      public_rpc_url: "https://fork.example.test",
      chain_id: 31_337,
      addresses: %{
        "regent" => "0x6f89bca4ea5931edfcb09786267b251dee752b07",
        "hook" => "0x" <> String.duplicate("1", 40)
      }
    }

    assert Lab.binding(config, [:regent]) == %{
             "run_id" => "preview",
             "rpc_url" => "https://fork.example.test",
             "chain_id" => 31_337,
             "addresses" => %{"regent" => "0x6f89bca4ea5931edfcb09786267b251dee752b07"}
           }

    refute Lab.binding(config, [:regent, :hook]) |> Jason.encode!() =~ "internal"
  end

  defp load(dir, doors, mode) do
    path = Path.join(dir, "#{mode}-#{:erlang.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(Map.put(doors, "chain_id", 31_337)))
    Lab.load(path, mode)
  end
end
