defmodule Autolaunch.Contracts.Dispatch do
  @moduledoc false

  alias Autolaunch.Contracts.Abi
  alias Autolaunch.Contracts.ActionParams
  alias Autolaunch.Revenue

  def build_job_action(job, "strategy", "migrate", _attrs) do
    ActionParams.prepare_tx(
      job.chain_id,
      job.strategy_address,
      Abi.encode_call(:migrate),
      "strategy",
      "migrate"
    )
  end

  def build_job_action(job, "strategy", "sweep_token", _attrs) do
    ActionParams.prepare_tx(
      job.chain_id,
      job.strategy_address,
      Abi.encode_call(:sweep_token),
      "strategy",
      "sweep_token"
    )
  end

  def build_job_action(job, "strategy", "sweep_currency", _attrs) do
    ActionParams.prepare_tx(
      job.chain_id,
      job.strategy_address,
      Abi.encode_call(:sweep_currency),
      "strategy",
      "sweep_currency"
    )
  end

  def build_job_action(job, "vesting", "release", _attrs) do
    ActionParams.prepare_tx(
      job.chain_id,
      job.vesting_wallet_address,
      Abi.encode_call(:release_launch_token),
      "vesting",
      "release"
    )
  end

  def build_job_action(job, "fee_registry", "set_hook_enabled", attrs) do
    with {:ok, enabled} <- ActionParams.boolean_param(attrs, "enabled") do
      ActionParams.prepare_tx(
        job.chain_id,
        job.launch_fee_registry_address,
        Abi.encode_call(:set_hook_enabled, [{:bytes32, job.pool_id}, {:bool, enabled}]),
        "fee_registry",
        "set_hook_enabled",
        %{enabled: enabled}
      )
    end
  end

  def build_job_action(job, "fee_vault", "withdraw_treasury", attrs) do
    with {:ok, currency} <- ActionParams.address_param(attrs, "currency"),
         {:ok, amount} <- ActionParams.uint_param(attrs, "amount"),
         {:ok, recipient} <- ActionParams.address_param(attrs, "recipient") do
      ActionParams.prepare_tx(
        job.chain_id,
        job.launch_fee_vault_address,
        Abi.encode_call(:withdraw_treasury, [
          {:bytes32, job.pool_id},
          {:address, currency},
          {:uint256, amount},
          {:address, recipient}
        ]),
        "fee_vault",
        "withdraw_treasury",
        %{currency: currency, amount: Integer.to_string(amount), recipient: recipient}
      )
    end
  end

  def build_job_action(job, "fee_vault", "withdraw_regent_share", attrs) do
    with {:ok, currency} <- ActionParams.address_param(attrs, "currency"),
         {:ok, amount} <- ActionParams.uint_param(attrs, "amount"),
         {:ok, recipient} <- ActionParams.address_param(attrs, "recipient") do
      ActionParams.prepare_tx(
        job.chain_id,
        job.launch_fee_vault_address,
        Abi.encode_call(:withdraw_regent_share, [
          {:bytes32, job.pool_id},
          {:address, currency},
          {:uint256, amount},
          {:address, recipient}
        ]),
        "fee_vault",
        "withdraw_regent_share",
        %{currency: currency, amount: Integer.to_string(amount), recipient: recipient}
      )
    end
  end

  def build_job_action(job, "fee_vault", "set_hook", attrs) do
    with {:ok, hook} <- ActionParams.address_param(attrs, "hook") do
      ActionParams.prepare_tx(
        job.chain_id,
        job.launch_fee_vault_address,
        Abi.encode_call(:set_hook, [{:address, hook}]),
        "fee_vault",
        "set_hook",
        %{hook: hook}
      )
    end
  end

  def build_job_action(_job, _resource, _action, _attrs), do: {:error, :unsupported_action}

  def build_subject_action(subject, _registry, "splitter", "set_paused", attrs, _config) do
    with {:ok, paused} <- ActionParams.boolean_param(attrs, "paused") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:set_paused, [{:bool, paused}]),
        "splitter",
        "set_paused",
        %{paused: paused}
      )
    end
  end

  def build_subject_action(subject, _registry, "splitter", "set_label", attrs, _config) do
    with {:ok, label} <- ActionParams.string_param(attrs, "label") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:set_label, [{:string, label}]),
        "splitter",
        "set_label",
        %{label: label}
      )
    end
  end

  def build_subject_action(
        subject,
        _registry,
        "splitter",
        "set_treasury_recipient",
        attrs,
        _config
      ) do
    with {:ok, recipient} <- ActionParams.address_param(attrs, "recipient") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:set_treasury_recipient, [{:address, recipient}]),
        "splitter",
        "set_treasury_recipient",
        %{recipient: recipient}
      )
    end
  end

  def build_subject_action(
        subject,
        _registry,
        "splitter",
        "set_protocol_recipient",
        attrs,
        _config
      ) do
    with {:ok, recipient} <- ActionParams.address_param(attrs, "recipient") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:set_protocol_recipient, [{:address, recipient}]),
        "splitter",
        "set_protocol_recipient",
        %{recipient: recipient}
      )
    end
  end

  def build_subject_action(
        subject,
        _registry,
        "splitter",
        "set_protocol_skim_bps",
        attrs,
        _config
      ) do
    with {:ok, skim_bps} <- ActionParams.uint_param(attrs, "skim_bps") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:set_protocol_skim_bps, [{:uint16, skim_bps}]),
        "splitter",
        "set_protocol_skim_bps",
        %{skim_bps: skim_bps}
      )
    end
  end

  def build_subject_action(
        subject,
        _registry,
        "splitter",
        "withdraw_treasury_residual",
        attrs,
        _config
      ) do
    with {:ok, amount} <- ActionParams.uint_param(attrs, "amount"),
         {:ok, recipient} <- ActionParams.address_param(attrs, "recipient") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:withdraw_treasury_residual_usdc, [
          {:uint256, amount},
          {:address, recipient}
        ]),
        "splitter",
        "withdraw_treasury_residual",
        %{amount: Integer.to_string(amount), recipient: recipient}
      )
    end
  end

  def build_subject_action(
        subject,
        _registry,
        "splitter",
        "withdraw_protocol_reserve",
        attrs,
        _config
      ) do
    with {:ok, amount} <- ActionParams.uint_param(attrs, "amount"),
         {:ok, recipient} <- ActionParams.address_param(attrs, "recipient") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:withdraw_protocol_reserve_usdc, [
          {:uint256, amount},
          {:address, recipient}
        ]),
        "splitter",
        "withdraw_protocol_reserve",
        %{amount: Integer.to_string(amount), recipient: recipient}
      )
    end
  end

  def build_subject_action(subject, _registry, "splitter", "reassign_dust", attrs, _config) do
    with {:ok, amount} <- ActionParams.uint_param(attrs, "amount") do
      ActionParams.prepare_tx(
        subject.chain_id,
        subject.splitter_address,
        Abi.encode_call(:reassign_undistributed_dust_to_treasury, [{:uint256, amount}]),
        "splitter",
        "reassign_dust",
        %{amount: Integer.to_string(amount)}
      )
    end
  end

  def build_subject_action(subject, _registry, "ingress_factory", "create", attrs, config) do
    with {:ok, label} <- ActionParams.string_param(attrs, "label"),
         {:ok, make_default} <- ActionParams.boolean_param(attrs, "make_default") do
      ActionParams.prepare_tx(
        subject.chain_id,
        config.ingress_factory_address,
        Abi.encode_call(:create_ingress_account, [
          {:bytes32, subject.subject_id},
          {:string, label},
          {:bool, make_default}
        ]),
        "ingress_factory",
        "create",
        %{label: label, make_default: make_default}
      )
    end
  end

  def build_subject_action(subject, _registry, "ingress_factory", "set_default", attrs, config) do
    with {:ok, ingress} <- ActionParams.address_param(attrs, "ingress_address") do
      ActionParams.prepare_tx(
        subject.chain_id,
        config.ingress_factory_address,
        Abi.encode_call(:set_default_ingress, [
          {:bytes32, subject.subject_id},
          {:address, ingress}
        ]),
        "ingress_factory",
        "set_default",
        %{ingress_address: ingress}
      )
    end
  end

  def build_subject_action(subject, _registry, "ingress_account", "set_label", attrs, _config) do
    with {:ok, ingress} <- ActionParams.address_param(attrs, "ingress_address"),
         {:ok, label} <- ActionParams.string_param(attrs, "label"),
         :ok <- ensure_known_ingress(subject, ingress) do
      ActionParams.prepare_tx(
        subject.chain_id,
        ingress,
        Abi.encode_call(:set_label, [{:string, label}]),
        "ingress_account",
        "set_label",
        %{ingress_address: ingress, label: label}
      )
    end
  end

  def build_subject_action(subject, _registry, "ingress_account", "rescue", attrs, _config) do
    with {:ok, ingress} <- ActionParams.address_param(attrs, "ingress_address"),
         {:ok, token} <- ActionParams.address_param(attrs, "token"),
         {:ok, amount} <- ActionParams.uint_param(attrs, "amount"),
         {:ok, recipient} <- ActionParams.address_param(attrs, "recipient"),
         :ok <- ensure_known_ingress(subject, ingress) do
      ActionParams.prepare_tx(
        subject.chain_id,
        ingress,
        Abi.encode_call(:rescue_token, [
          {:address, token},
          {:uint256, amount},
          {:address, recipient}
        ]),
        "ingress_account",
        "rescue",
        %{
          ingress_address: ingress,
          token: token,
          amount: Integer.to_string(amount),
          recipient: recipient
        }
      )
    end
  end

  def build_subject_action(subject, _registry, "ingress_account", "sweep", attrs, _config) do
    with {:ok, ingress} <- ActionParams.address_param(attrs, "ingress_address"),
         :ok <- ensure_known_ingress(subject, ingress) do
      ActionParams.prepare_tx(
        subject.chain_id,
        ingress,
        Revenue.Abi.encode_sweep_usdc(subject.subject_id),
        "ingress_account",
        "sweep",
        %{ingress_address: ingress}
      )
    end
  end

  def build_subject_action(subject, registry, "registry", "set_subject_manager", attrs, _config) do
    with {:ok, account} <- ActionParams.address_param(attrs, "account"),
         {:ok, enabled} <- ActionParams.boolean_param(attrs, "enabled") do
      ActionParams.prepare_tx(
        subject.chain_id,
        registry.address,
        Abi.encode_call(:set_subject_manager, [
          {:bytes32, subject.subject_id},
          {:address, account},
          {:bool, enabled}
        ]),
        "registry",
        "set_subject_manager",
        %{account: account, enabled: enabled}
      )
    end
  end

  def build_subject_action(subject, registry, "registry", "link_identity", attrs, _config) do
    with {:ok, chain_id} <- ActionParams.uint_param(attrs, "identity_chain_id"),
         {:ok, identity_registry} <- ActionParams.address_param(attrs, "identity_registry"),
         {:ok, agent_id} <- ActionParams.uint_param(attrs, "identity_agent_id") do
      ActionParams.prepare_tx(
        subject.chain_id,
        registry.address,
        Abi.encode_call(:link_identity, [
          {:bytes32, subject.subject_id},
          {:uint256, chain_id},
          {:address, identity_registry},
          {:uint256, agent_id}
        ]),
        "registry",
        "link_identity",
        %{
          identity_chain_id: chain_id,
          identity_registry: identity_registry,
          identity_agent_id: agent_id
        }
      )
    end
  end

  def build_subject_action(_subject, _registry, _resource, _action, _attrs, _config),
    do: {:error, :unsupported_action}

  def build_admin_action("revenue_share_factory", "set_authorized_creator", attrs, config) do
    with {:ok, account} <- ActionParams.address_param(attrs, "account"),
         {:ok, enabled} <- ActionParams.boolean_param(attrs, "enabled") do
      ActionParams.prepare_tx(
        config.chain_id,
        config.revenue_share_factory_address,
        Abi.encode_call(:set_authorized_creator, [{:address, account}, {:bool, enabled}]),
        "revenue_share_factory",
        "set_authorized_creator",
        %{account: account, enabled: enabled}
      )
    end
  end

  def build_admin_action("revenue_ingress_factory", "set_authorized_creator", attrs, config) do
    with {:ok, account} <- ActionParams.address_param(attrs, "account"),
         {:ok, enabled} <- ActionParams.boolean_param(attrs, "enabled") do
      ActionParams.prepare_tx(
        config.chain_id,
        config.ingress_factory_address,
        Abi.encode_call(:set_authorized_creator, [{:address, account}, {:bool, enabled}]),
        "revenue_ingress_factory",
        "set_authorized_creator",
        %{account: account, enabled: enabled}
      )
    end
  end

  def build_admin_action(_resource, _action, _attrs, _config), do: {:error, :unsupported_action}

  defp ensure_known_ingress(subject, ingress_address) do
    if Enum.any?(subject.ingress_accounts, &(&1.address == ingress_address)) do
      :ok
    else
      {:error, :ingress_not_found}
    end
  end
end
