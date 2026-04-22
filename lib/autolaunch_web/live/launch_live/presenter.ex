defmodule AutolaunchWeb.LaunchLive.Presenter do
  @moduledoc false

  def regent_step_title(1), do: "Choose an eligible agent"
  def regent_step_title(2), do: "Set launch terms"
  def regent_step_title(3), do: "Review and sign"
  def regent_step_title(4), do: "Queue and monitor"
  def regent_step_title(5), do: "Deployment status"
  def regent_step_title(_step), do: "Launch control"

  def regent_step_summary(1, _selected_agent, _current_job),
    do:
      "Pick the identity that is allowed to launch. Use the review cards to confirm the details before you continue."

  def regent_step_summary(2, selected_agent, _current_job),
    do:
      "Set the Agent Safe for #{(selected_agent && (selected_agent.name || selected_agent.agent_id)) || "the chosen identity"} before you sign."

  def regent_step_summary(3, _selected_agent, _current_job),
    do:
      "This is the last chance to review the fixed supply, Agent Safe, and the optional trust check before you sign."

  def regent_step_summary(4, _selected_agent, current_job),
    do:
      "The launch is queued. Keep the page open and watch for the next step. Current state: #{regent_job_status(current_job)}."

  def regent_step_summary(5, _selected_agent, current_job),
    do: "The launch is now being tracked. Current state: #{regent_job_status(current_job)}."

  def regent_step_summary(_step, _selected_agent, _current_job),
    do: "Launch control is live."

  def regent_job_status(nil), do: "Awaiting queue"
  def regent_job_status(%{job: %{status: status}}), do: String.replace(status, "_", " ")

  def short_address(nil), do: "pending"

  def short_address(address) when is_binary(address) do
    address
    |> String.downcase()
    |> then(fn value ->
      if String.length(value) > 12 do
        String.slice(value, 0, 6) <> "..." <> String.slice(value, -4, 4)
      else
        value
      end
    end)
  end

  def access_mode_label("owner"), do: "Owner"
  def access_mode_label("operator"), do: "Operator"
  def access_mode_label("wallet_bound"), do: "Wallet-bound"
  def access_mode_label(_mode), do: "Unknown"

  def disabled_agent_message(%{state: "already_launched"}),
    do: "This identity already has an Agent Coin."

  def disabled_agent_message(%{access_mode: "wallet_bound"}),
    do: "This identity can only be used from its connected wallet."

  def disabled_agent_message(_agent),
    do: "Finish the missing setup before launch."

  def reputation_action_status("complete"), do: "Complete"
  def reputation_action_status("available"), do: "Ready now"
  def reputation_action_status("pending"), do: "Available after launch"
  def reputation_action_status(_status), do: "Optional"

  def launch_command, do: "regent autolaunch prelaunch wizard"

  def launch_cli_transcript do
    """
    > regent autolaunch prelaunch validate --plan plan_alpha
    > regent autolaunch prelaunch publish --plan plan_alpha
    > regent autolaunch launch run --plan plan_alpha --watch
    > regent autolaunch launch monitor --job job_alpha --watch
    > regent autolaunch launch finalize --job job_alpha --submit
    """
    |> String.trim()
  end

  def launch_inputs do
    [
      %{
        title: "Identity",
        value: "The launch identity and the wallet that controls it",
        body: "Use the wallet that can sign for this identity."
      },
      %{
        title: "Token basics",
        value: "Name, symbol, and minimum USDC raise",
        body:
          "Set the minimum amount you want to raise. If the sale does not reach it, buyers can get their money back."
      },
      %{
        title: "Treasury routing",
        value: "One Agent Safe for treasury, vesting, and contract ownership",
        body:
          "Use one Safe for treasury, vesting, and contract control. Check it carefully before you launch."
      },
      %{
        title: "Hosted metadata",
        value: "Title, description, and image",
        body:
          "The launch tool can upload the image and save the launch details before you publish and start."
      }
    ]
  end

  def launch_checklist(current_human) do
    [
      %{
        title: "Operator wallet connected",
        detail: short_address(current_human && current_human.wallet_address),
        status: if(current_human, do: "Connected", else: "Needed")
      },
      %{title: "Network", detail: "Base Sepolia (testnet)", status: "Ready"},
      %{title: "Agent profile", detail: "Display name, links, metadata", status: "Ready"},
      %{title: "Fees and allocations", detail: "Launch fee 1%, Creator 5%", status: "Ready"},
      %{title: "Assets", detail: "Logo, banner, description", status: "Optional"},
      %{title: "Review and confirm", detail: "Preview and launch", status: "Pending"}
    ]
  end

  def launch_flow do
    [
      %{index: 1, label: "Save plan"},
      %{index: 2, label: "Validate"},
      %{index: 3, label: "Publish"},
      %{index: 4, label: "Run"},
      %{index: 5, label: "Monitor"},
      %{index: 6, label: "Finalize"}
    ]
  end

  def launch_console_steps do
    [
      %{
        title: "Deploy",
        body: "Deploy the Safe, strategy, splitter, ingress, and registry."
      },
      %{
        title: "Fund",
        body: "Fund the strategy and set the launch allocations."
      },
      %{
        title: "Go live",
        body: "Start the market on Base and keep the operator run moving."
      }
    ]
  end

  def direct_operator_cards do
    [
      %{
        title: "What to run",
        body: "Follow the guided command line steps from saved plan to live market."
      },
      %{
        title: "What happens next",
        body: "The contracts are prepared and the launch is ready for review."
      },
      %{
        title: "You go live",
        body: "Review once more, then launch when the market setup is right."
      }
    ]
  end

  def operator_guides do
    [
      %{
        eyebrow: "OpenClaw",
        title: "Autonomous launch operator",
        status: "Recommended",
        copy_label: "Copy OpenClaw brief",
        prompt: """
        Use Autolaunch to prepare and run a token launch for me.

        Start with `regent autolaunch prelaunch wizard`.
        Ask me for any missing launch details before you continue.
        Save the plan, validate it, publish it, run the launch, and monitor the auction.
        Stop for confirmation before every signing step and explain what happens next in plain English.
        """
      },
      %{
        eyebrow: "Hermes",
        title: "Guided agent assistant",
        status: nil,
        copy_label: "Copy Hermes brief",
        prompt: """
        Help me launch through Autolaunch as an operator.

        Begin with `regent autolaunch prelaunch wizard`.
        Keep the saved plan as the source of truth.
        Walk me through validate, publish, launch, and monitor in order.
        Before each signing step, tell me what it will do and what to check after it lands.
        """
      }
    ]
  end

  def agent_assisted_cards do
    [
      %{
        title: "What to run",
        body: "Grant permissions, hand over the launch brief, and let the agent carry the run."
      },
      %{
        title: "What happens next",
        body: "The agent keeps the launch moving and reports each checkpoint in plain English."
      },
      %{
        title: "You go live",
        body: "Approve the signing steps and send the market live when the plan is ready."
      }
    ]
  end

  def launch_via_agent_path do
    [
      %{
        step: "01",
        title: "Start with a saved launch plan.",
        body:
          "Start in the command line with a saved plan. Do not skip straight to launch settings."
      },
      %{
        step: "02",
        title: "Validate and publish before you run.",
        body: "Check the plan, then publish the launch details so nothing changes after you sign."
      },
      %{
        step: "03",
        title: "Run the launch and watch the sale.",
        body:
          "Use the command line to start the launch, track the sale, and wait for the next steps."
      },
      %{
        step: "04",
        title: "Handle the final steps after the sale.",
        body:
          "After the sale, finish the remaining steps, then check vesting when releases are ready."
      }
    ]
  end

  def launch_agent_transcript do
    """
    > regent autolaunch prelaunch validate
    > regent autolaunch prelaunch publish
    > regent autolaunch launch run --plan plan_alpha
    > regent autolaunch launch monitor --job job_alpha
    > regent autolaunch launch finalize --job job_alpha
    > regent autolaunch vesting status --job job_alpha
    """
    |> String.trim()
  end
end
