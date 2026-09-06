defmodule AutolaunchWeb.Components.AutolaunchHelpersTest do
  use ExUnit.Case, async: true

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [page_status: 2]

  alias Phoenix.LiveView.AsyncResult

  test "page status distinguishes loading, ready, missing and failed reads" do
    loading = AsyncResult.loading()

    assert page_status(loading, :error) == :loading
    assert page_status(AsyncResult.ok(%{status: :ready}), :error) == :ready
    assert page_status(AsyncResult.ok(%{status: :empty}), :error) == :empty
    assert page_status(AsyncResult.failed(loading, {:error, :unavailable}), :error) == :error
    assert page_status(AsyncResult.failed(loading, {:exit, :killed}), :error) == :error
  end

  test "a failed refresh keeps the last successful page" do
    refreshing = AsyncResult.loading(AsyncResult.ok(%{status: :ready}))

    assert page_status(AsyncResult.failed(refreshing, {:error, :unavailable}), :error) == :ready
  end
end
