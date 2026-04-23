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

  def launch_readiness(current_human, launch_module, prelaunch_module) do
    wallet_address = current_human && current_human.wallet_address
    agents = launch_agents(launch_module, current_human)
    eligible_agents = Enum.filter(agents, &(&1.state == "eligible"))
    plans = prelaunch_plans(prelaunch_module, current_human)
    active_plan = active_plan(plans)

    steps = [
      wallet_step(wallet_address),
      profile_step(current_human),
      agent_step(current_human, eligible_agents),
      plan_step(current_human, eligible_agents, active_plan),
      market_step(active_plan)
    ]

    %{
      wallet_address: wallet_address,
      active_plan: active_plan,
      eligible_agent_count: length(eligible_agents),
      steps: steps,
      next_action: next_action(steps, active_plan),
      enrichment: enrichment_status(active_plan),
      trust_actions: trust_actions(active_plan)
    }
  end

  def metadata_form(nil) do
    %{
      "title" => "",
      "subtitle" => "",
      "description" => "",
      "website_url" => "",
      "image_url" => ""
    }
  end

  def metadata_form(%{"title" => _} = attrs) do
    metadata_form(nil)
    |> Map.merge(Map.take(attrs, ~w(title subtitle description website_url image_url)))
  end

  def metadata_form(%{metadata_draft: metadata}) when is_map(metadata) do
    %{
      "title" => metadata["title"] || "",
      "subtitle" => metadata["subtitle"] || "",
      "description" => metadata["description"] || "",
      "website_url" => metadata["website_url"] || "",
      "image_url" => metadata["image_url"] || ""
    }
  end

  def metadata_form(_value), do: metadata_form(nil)

  def metadata_preview(nil) do
    %{
      title: "No saved plan yet",
      subtitle: "Start from the CLI",
      description: "Save a launch plan, then come back here to finish public details.",
      image_url: nil,
      website_url: nil
    }
  end

  def metadata_preview(%{"title" => _} = attrs) do
    form = metadata_form(attrs)

    %{
      title: present_text(form["title"]) || "Untitled launch",
      subtitle: present_text(form["subtitle"]) || "Public launch preview",
      description: present_text(form["description"]) || "Add a public description before launch.",
      image_url: present_text(form["image_url"]),
      website_url: present_text(form["website_url"])
    }
  end

  def metadata_preview(%{
        title: title,
        subtitle: subtitle,
        description: description,
        image_url: image_url,
        website_url: website_url
      }) do
    %{
      title: present_text(title) || "Untitled launch",
      subtitle: present_text(subtitle) || "Public launch preview",
      description: present_text(description) || "Add a public description before launch.",
      image_url: present_text(image_url),
      website_url: present_text(website_url)
    }
  end

  def metadata_preview(%{metadata_draft: metadata, identity_snapshot: snapshot} = plan) do
    metadata = metadata || %{}
    snapshot = snapshot || %{}

    %{
      title:
        present_text(metadata["title"]) || present_text(snapshot["name"]) ||
          present_text(plan[:token_name]) || "Untitled launch",
      subtitle: present_text(metadata["subtitle"]) || "Public launch preview",
      description:
        present_text(metadata["description"]) || present_text(snapshot["description"]) ||
          "Add a public description before launch.",
      image_url: present_text(metadata["image_url"]) || present_text(snapshot["image_url"]),
      website_url: present_text(metadata["website_url"]) || present_text(snapshot["web_endpoint"])
    }
  end

  def metadata_preview(_value), do: metadata_preview(nil)

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
    launch_readiness(current_human, Autolaunch.Launch, Autolaunch.Prelaunch).steps
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

  defp launch_agents(_launch_module, nil), do: []

  defp launch_agents(launch_module, current_human) do
    launch_module.list_agents(current_human)
  rescue
    _ -> []
  end

  defp prelaunch_plans(_prelaunch_module, nil), do: []

  defp prelaunch_plans(prelaunch_module, current_human) do
    case prelaunch_module.list_plans(current_human) do
      {:ok, plans} when is_list(plans) -> plans
      _ -> []
    end
  rescue
    _ -> []
  end

  defp active_plan(plans) do
    Enum.find(plans, &(Map.get(&1, :state) in ["launchable", "validated", "draft", "launched"])) ||
      List.first(plans)
  end

  defp wallet_step(wallet_address) when is_binary(wallet_address) and wallet_address != "" do
    %{
      key: "wallet",
      title: "Operator wallet",
      detail: short_address(wallet_address),
      status: "Connected"
    }
  end

  defp wallet_step(_wallet_address) do
    %{
      key: "wallet",
      title: "Operator wallet",
      detail: "Connect a wallet before preparing a launch.",
      status: "Needed"
    }
  end

  defp profile_step(nil) do
    %{
      key: "profile",
      title: "Operator profile",
      detail: "Sign in so Autolaunch can keep your launch work together.",
      status: "Needed"
    }
  end

  defp profile_step(current_human) do
    display_name = display_name(current_human)

    %{
      key: "profile",
      title: "Operator profile",
      detail: display_name || "Add a profile name before handing work to an agent.",
      status: if(display_name, do: "Ready", else: "Needed")
    }
  end

  defp agent_step(nil, _eligible_agents) do
    %{
      key: "agent",
      title: "Agent identity",
      detail: "Connect a wallet so launch-ready identities can be checked.",
      status: "Needed"
    }
  end

  defp agent_step(_current_human, []) do
    %{
      key: "agent",
      title: "Agent identity",
      detail: "No launch-ready identity is connected to this wallet yet.",
      status: "Needed"
    }
  end

  defp agent_step(_current_human, eligible_agents) do
    count = length(eligible_agents)

    %{
      key: "agent",
      title: "Agent identity",
      detail: "#{count} #{pluralize(count, "identity", "identities")} ready for launch.",
      status: "Ready"
    }
  end

  defp plan_step(nil, _eligible_agents, _active_plan) do
    %{
      key: "plan",
      title: "Launch plan",
      detail: "Connect a wallet before saving a launch plan.",
      status: "Needed"
    }
  end

  defp plan_step(_current_human, [], _active_plan) do
    %{
      key: "plan",
      title: "Launch plan",
      detail: "Choose a launch-ready identity before saving a plan.",
      status: "Needed"
    }
  end

  defp plan_step(_current_human, _eligible_agents, nil) do
    %{
      key: "plan",
      title: "Launch plan",
      detail: "No saved plan yet. Start the guided setup from the command line.",
      status: "Needed"
    }
  end

  defp plan_step(_current_human, _eligible_agents, %{state: "launched"} = plan) do
    %{
      key: "plan",
      title: "Launch plan",
      detail: "#{plan_name(plan)} has moved into launch tracking.",
      status: "Live"
    }
  end

  defp plan_step(_current_human, _eligible_agents, %{state: "launchable"} = plan) do
    %{
      key: "plan",
      title: "Launch plan",
      detail: "#{plan_name(plan)} is ready to publish and run.",
      status: "Ready"
    }
  end

  defp plan_step(_current_human, _eligible_agents, %{state: state} = plan)
       when state in ["draft", "validated"] do
    %{
      key: "plan",
      title: "Launch plan",
      detail: "#{plan_name(plan)} is saved. Continue review before launch.",
      status: "In progress"
    }
  end

  defp plan_step(_current_human, _eligible_agents, _active_plan) do
    %{
      key: "plan",
      title: "Launch plan",
      detail: "Review the saved plan before launch.",
      status: "In progress"
    }
  end

  defp market_step(%{state: "launched", launch_job_id: launch_job_id})
       when is_binary(launch_job_id) do
    %{
      key: "market",
      title: "Market tracking",
      detail: "Launch tracking is open for #{launch_job_id}.",
      status: "Live"
    }
  end

  defp market_step(%{state: "launchable"}) do
    %{
      key: "market",
      title: "Market tracking",
      detail: "Run the plan when you are ready to open the market.",
      status: "Ready"
    }
  end

  defp market_step(_active_plan) do
    %{
      key: "market",
      title: "Market tracking",
      detail: "Market tracking opens after the launch starts.",
      status: "Needed"
    }
  end

  defp next_action(steps, active_plan) do
    blocked = Enum.find(steps, &(&1.status == "Needed"))

    cond do
      blocked && blocked.key in ["wallet", "profile"] ->
        %{
          title: "Connect your operator profile",
          body:
            "Open your profile, connect the wallet you will use, and return here when it is ready.",
          label: "Open profile",
          path: "/profile",
          copy_command: false
        }

      blocked && blocked.key == "agent" ->
        %{
          title: "Connect a launch-ready identity",
          body: "Use a wallet that controls the agent identity you want to launch.",
          label: "Open profile",
          path: "/profile",
          copy_command: false
        }

      blocked && blocked.key == "plan" ->
        command_action(
          "Save the launch plan",
          "Start the guided setup, choose the identity, and save the launch terms before review.",
          "Copy starter command"
        )

      active_plan && active_plan.state in ["draft", "validated"] ->
        command_action(
          "Continue the saved plan",
          "Review the saved plan, add any missing public details, and publish it when it is ready.",
          "Copy review command"
        )

      active_plan && active_plan.state == "launchable" ->
        command_action(
          "Run the launch",
          "Publish and run the plan when the final review is clear.",
          "Copy launch command"
        )

      active_plan && active_plan.state == "launched" ->
        %{
          title: "Track launch work",
          body:
            "Review contract steps, market status, and holder follow-up while launch tracking is open.",
          label: "Open contracts",
          path: "/contracts",
          copy_command: false
        }

      true ->
        command_action(
          "Review launch setup",
          "Use the guided setup to prepare the next launch plan.",
          "Copy starter command"
        )
    end
  end

  defp command_action(title, body, label) do
    %{
      title: title,
      body: body,
      label: label,
      path: nil,
      copy_command: true,
      command: launch_command()
    }
  end

  defp enrichment_status(nil) do
    %{
      status: "Needed",
      missing: ["Save a launch plan from the CLI."]
    }
  end

  defp enrichment_status(plan) do
    preview = metadata_preview(plan)

    missing =
      []
      |> maybe_missing(preview.title in ["Untitled launch", nil, ""], "Add a title.")
      |> maybe_missing(
        preview.description in ["Add a public description before launch.", nil, ""],
        "Add a description."
      )
      |> maybe_missing(is_nil(preview.image_url) or preview.image_url == "", "Add an image.")

    %{
      status: if(missing == [], do: "Ready", else: "Needed"),
      missing: missing
    }
  end

  defp trust_actions(%{state: "launched", launch_job_id: launch_job_id})
       when is_binary(launch_job_id) do
    [
      %{label: "Open AgentBook", path: "/agentbook?launch_job_id=#{URI.encode(launch_job_id)}"},
      %{label: "Open ENS", path: "/ens-link"},
      %{label: "Open X", path: "/x-link"},
      %{label: "Open contracts", path: "/contracts"}
    ]
  end

  defp trust_actions(%{} = _plan) do
    [
      %{label: "Open Profile", path: "/profile"},
      %{label: "Open ENS", path: "/ens-link"},
      %{label: "Open X", path: "/x-link"},
      %{label: "Open AgentBook", path: "/agentbook"}
    ]
  end

  defp trust_actions(_plan) do
    [
      %{label: "Open Profile", path: "/profile"}
    ]
  end

  defp display_name(current_human) do
    current_human
    |> Map.get(:display_name)
    |> present_text()
  end

  defp plan_name(%{token_symbol: symbol}) when is_binary(symbol) and symbol != "",
    do: "#{symbol} plan"

  defp plan_name(%{token_name: name}) when is_binary(name) and name != "", do: name
  defp plan_name(%{agent_name: name}) when is_binary(name) and name != "", do: name
  defp plan_name(_plan), do: "Launch plan"

  defp present_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp present_text(_value), do: nil

  defp maybe_missing(missing, true, message), do: missing ++ [message]
  defp maybe_missing(missing, _condition, _message), do: missing

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
