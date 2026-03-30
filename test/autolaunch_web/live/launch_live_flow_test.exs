defmodule AutolaunchWeb.LaunchLiveFlowTest do
  use ExUnit.Case, async: true

  alias AutolaunchWeb.LaunchLive.{Flow, Presenter}

  test "default_form mirrors the connected wallet into the operator addresses" do
    form = Flow.default_form(%{wallet_address: "0x1111111111111111111111111111111111111111"})

    assert form["recovery_safe_address"] == "0x1111111111111111111111111111111111111111"
    assert form["auction_proceeds_recipient"] == "0x1111111111111111111111111111111111111111"
    assert form["ethereum_revenue_treasury"] == "0x1111111111111111111111111111111111111111"
  end

  test "max_available_step follows selected agent, preview, and queued job state" do
    assert Flow.max_available_step(%{job_id: nil, preview: nil, selected_agent: nil}) == 1
    assert Flow.max_available_step(%{job_id: nil, preview: nil, selected_agent: %{}}) == 2
    assert Flow.max_available_step(%{job_id: nil, preview: %{}, selected_agent: %{}}) == 3
    assert Flow.max_available_step(%{job_id: "job_1", preview: %{}, selected_agent: %{}}) == 5
  end

  test "presenter keeps launch summaries and address formatting stable" do
    assert Presenter.regent_step_title(3) == "Review and sign"

    assert Presenter.regent_job_status(%{job: %{status: "waiting_for_receipt"}}) ==
             "waiting for receipt"

    assert Presenter.short_address("0x1111111111111111111111111111111111111111") ==
             "0x1111...1111"
  end
end
