defmodule Autolaunch.LabTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Lab

  @moduletag :tmp_dir

  # Validation stops at the first refused key, so a description holding only
  # the RPC doors and the chain id proves which doors are admitted: an admitted
  # pair reaches the address check (`:invalid_addresses`), a refused one never
  # does.
  test "the site's door is loopback, private or https; every other door needs a public one", %{
    tmp_dir: dir
  } do
    loopback = "http://127.0.0.1:8545"
    internal = "http://autolaunch-fork.internal:8545"
    https = "https://base-admin.example.test/rpc"
    public = "https://base.example.test"

    # Loopback with no public door: the local lab shape; wallets get loopback.
    assert {:error, :invalid_addresses} = load(dir, %{"rpc_url" => loopback})

    # A private or https own door requires the public door wallets use.
    assert {:error, :missing_public_rpc} = load(dir, %{"rpc_url" => internal})
    assert {:error, :missing_public_rpc} = load(dir, %{"rpc_url" => https})

    assert {:error, :invalid_addresses} =
             load(dir, %{"rpc_url" => internal, "public_rpc_url" => public})

    assert {:error, :invalid_addresses} =
             load(dir, %{"rpc_url" => https, "public_rpc_url" => public})

    # Plain http outside loopback and the private network is never the site's door.
    assert {:error, :rpc_not_admitted} =
             load(dir, %{"rpc_url" => "http://base.example.test:8545", "public_rpc_url" => public})

    # Neither door carries credentials, a query or a fragment.
    for own <- [
          "http://user:secret@autolaunch-fork.internal:8545",
          "http://autolaunch-fork.internal:8545?x=1",
          "https://base-admin.example.test/rpc#x"
        ] do
      assert {:error, :rpc_not_admitted} =
               load(dir, %{"rpc_url" => own, "public_rpc_url" => public})
    end

    # The public door is https and nothing else.
    for wallet_door <- [
          "http://base.example.test",
          "http://127.0.0.1:8545",
          "https://user:secret@base.example.test",
          "https://base.example.test?x=1",
          ""
        ] do
      assert {:error, :invalid_public_rpc} =
               load(dir, %{"rpc_url" => internal, "public_rpc_url" => wallet_door})
    end
  end

  test "the chain id is whatever positive integer the description names", %{tmp_dir: dir} do
    doors = %{"rpc_url" => "http://127.0.0.1:8545"}

    assert {:error, :invalid_addresses} = load(dir, doors, 8453)
    assert {:error, :invalid_addresses} = load(dir, doors, 31_337)
    assert {:error, :invalid_chain_id} = load(dir, doors, 0)
    assert {:error, :invalid_chain_id} = load(dir, doors, "8453")
    assert {:error, :invalid_chain_id} = load(dir, doors, nil)
  end

  test "a test chain keeps the start blocks it names, and may name none", %{tmp_dir: dir} do
    fixture =
      "../fixtures/base-deployment.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("chain_id", 31_337)

    named = Path.join(dir, "named.json")
    File.write!(named, Jason.encode!(fixture))
    assert {:ok, %{start_blocks: %{"factory" => _block} = blocks}} = Lab.load(named)
    assert blocks == fixture["start_blocks"]

    unnamed = Path.join(dir, "unnamed.json")
    File.write!(unnamed, Jason.encode!(Map.delete(fixture, "start_blocks")))
    assert {:ok, %{start_blocks: %{}}} = Lab.load(unnamed)
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

  defp load(dir, doors, chain_id \\ 31_337) do
    path = Path.join(dir, "description-#{:erlang.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(Map.put(doors, "chain_id", chain_id)))
    Lab.load(path)
  end
end
