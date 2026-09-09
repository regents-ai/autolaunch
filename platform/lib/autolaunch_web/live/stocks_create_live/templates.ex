defmodule AutolaunchWeb.Live.StocksCreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.StockCurrencySelect

  alias Autolaunch.Stocks.{Amounts, LaunchActions, LaunchDraft}
  alias Autolaunch.Stocks.LaunchOperation.Validations.ActiveLaunchLimit

  @new_decimals 18
  @address_hint "0x followed by exactly 40 hexadecimal characters."

  @token_fields [
    %{param: "name", label: "Name", kind: :text, hint: "Up to 64 bytes."},
    %{param: "symbol", label: "Symbol", kind: :text, hint: "Up to 16 bytes."},
    %{param: "description", label: "Description", kind: :long_text, hint: "Up to 512 bytes."},
    %{param: "website", label: "Website", kind: :text, hint: "A link readers can open."},
    %{
      param: "image",
      label: "Image link",
      kind: :text,
      hint: "An https link to a PNG, JPEG or WebP image, up to 256 bytes."
    }
  ]

  @sections %{
    "autosave_stocks_token_details" => ~w(name symbol description website image),
    "autosave_stocks_terms" =>
      ~w(stock_address start_local start_timezone minimum_raise floor_price),
    "autosave_stocks_revenue" => ~w(subject_enabled subject_splitter fee_administrator)
  }

  @stored_params ~w(name symbol description website image stock_address start_local
    start_timezone minimum_raise floor_price subject_enabled subject_splitter fee_administrator)

  def section_params(event), do: Map.fetch!(@sections, event)
  def draft_field_params, do: @stored_params

  def blank_draft_fields,
    do: @stored_params |> Map.new(&{&1, ""}) |> Map.put("subject_enabled", "false")

  def draft_values(nil), do: blank_draft_fields()

  def draft_values(draft) do
    @stored_params
    |> Map.new(fn
      "start_local" -> {"start_local", start_local(draft.start_at, draft.start_timezone)}
      "subject_enabled" -> {"subject_enabled", to_string(draft.subject_enabled)}
      param -> {param, Map.get(draft, String.to_existing_atom(param)) || ""}
    end)
  end

  # The wall-clock text a `datetime-local` control shows for the stored instant.
  defp start_local(%DateTime{} = utc, zone) when is_binary(zone) do
    case DateTime.shift_zone(utc, zone) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%dT%H:%M")
      {:error, _reason} -> ""
    end
  end

  defp start_local(_start_at, _zone), do: ""

  attr :draft, :map, default: nil
  attr :draft_values, :map, required: true
  attr :draft_errors, :map, required: true
  attr :draft_notice, :map, default: nil
  attr :stocks_lab, :map, default: nil
  attr :active_stocks_launch, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :account_control, :map, required: true
  attr :status, :atom, default: :ready

  def create(assigns) do
    draft = assigns.draft

    assigns =
      assigns
      |> assign(:token_complete?, draft && LaunchDraft.token_details_complete?(draft))
      |> assign(:terms_complete?, draft && LaunchDraft.terms_complete?(draft))
      |> assign(:revenue_complete?, draft && LaunchDraft.revenue_complete?(draft))
      |> assign(:launch_ready?, draft && LaunchDraft.launch_ready?(draft))
      |> assign(:stock, stock_for(assigns.stocks_lab, assigns.draft_values["stock_address"]))
      |> assign(:subject_enabled?, assigns.draft_values["subject_enabled"] == "true")
      |> assign(:token_fields, @token_fields)
      |> assign(:address_hint, @address_hint)

    assigns =
      assign(assigns, :floor_echo, floor_echo(assigns.draft_values["floor_price"], assigns.stock))

    ~H"""
    <section id="autolaunch-stocks-create" class="autolaunch-page launchpad-create">
      <header class="launchpad-create__header">
        <p class="autolaunch-kicker">Autolaunch · Create · Stocks</p>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">Launch a stock-paired auction</h1>
        </Regent.Structure.section_bar>
        <p>
          Describe the new token, choose the Base stock token bidders pay with, set the start and
          the prices, then review the exact transactions your wallet sends. Draft changes save
          privately to your account.
        </p>
      </header>

      <p :if={@active_stocks_launch} class="launchpad-limit" role="status">
        {ActiveLaunchLimit.message()}
      </p>

      <p :if={@status == :error} class="autolaunch-empty">
        Your draft could not be loaded. Refresh and try again.
      </p>

      <section
        :if={@status != :error}
        class="launchpad-create__workspace"
        aria-labelledby="stocks-draft-title"
      >
        <div class="launchpad-create__form-column">
          <form
            id="stocks-token-details"
            phx-change="autosave_stocks_token_details"
            phx-submit="autosave_stocks_token_details"
            class="launchpad-form-section rg-panel rg-panel--surface rg-field"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Public identity</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label" id="stocks-draft-title">Token details</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{stage_status(@token_complete?)}</span>
            </header>
            <div class="launchpad-form-grid">
              <.draft_field
                :for={field <- @token_fields}
                field={field}
                form_id="stocks-token-details"
                value={@draft_values[field.param]}
                error={@draft_errors[field.param]}
              />
            </div>
            <img
              :if={@draft_values["image"] =~ ~r/\Ahttps:\/\//}
              class="autolaunch-image-preview"
              src={@draft_values["image"]}
              alt="Token image"
            />
          </form>

          <form
            id="stocks-terms"
            phx-change="autosave_stocks_terms"
            phx-submit="autosave_stocks_terms"
            phx-hook="AutolaunchZonedStart"
            class="launchpad-form-section rg-panel rg-panel--surface rg-field"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Currency and schedule</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Stock and auction terms</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{stage_status(@terms_complete?)}</span>
            </header>

            <.stock_currency_select
              id="stocks-terms-stock_address"
              name="stock_draft[stock_address]"
              value={@draft_values["stock_address"]}
            />
            <p :if={@draft_errors["stock_address"]} class="autolaunch-draft-error" role="alert">
              {@draft_errors["stock_address"]}
            </p>
            <p :if={@stock} class="autolaunch-draft-hint">
              {@stock.symbol} uses {@stock.decimals} decimal places on this site's Base fork.
            </p>

            <Regent.Primitives.field
              id="stocks-terms-start_local"
              label="Bidding opens"
              class="autolaunch-draft-field"
            >
              <input
                type="datetime-local"
                id="stocks-terms-start_local"
                name="stock_draft[start_local]"
                value={@draft_values["start_local"]}
                step="60"
                aria-describedby="stocks-terms-start_local-hint"
                phx-debounce="400"
              />
              <p id="stocks-terms-start_local-hint" class="autolaunch-draft-hint">
                At least 10 minutes and at most 30 days from when you review. Bidding runs about 24 hours.
              </p>
              <label for="stocks-terms-start_timezone">Time zone</label>
              <input
                type="text"
                id="stocks-terms-start_timezone"
                name="stock_draft[start_timezone]"
                value={@draft_values["start_timezone"]}
                autocomplete="off"
                placeholder="Detected from your browser"
                aria-describedby="stocks-terms-start_timezone-hint"
                phx-debounce="400"
                data-zoned-start-timezone
              />
              <p id="stocks-terms-start_timezone-hint" class="autolaunch-draft-hint">
                The zone the time above is written in, such as Europe/Amsterdam. Filled in from your browser; change it if you mean another zone.
              </p>
              <p :if={@draft_errors["start_local"]} class="autolaunch-draft-error" role="alert">
                {@draft_errors["start_local"]}
              </p>
              <p :if={@draft_errors["start_timezone"]} class="autolaunch-draft-error" role="alert">
                {@draft_errors["start_timezone"]}
              </p>
            </Regent.Primitives.field>

            <.draft_field
              field={
                %{
                  param: "minimum_raise",
                  label: "Minimum raise in #{symbol(@stock)}",
                  kind: :text,
                  hint:
                    "Digits and one decimal point. The auction refunds every bid if this is not reached."
                }
              }
              form_id="stocks-terms"
              value={@draft_values["minimum_raise"]}
              error={@draft_errors["minimum_raise"]}
            />

            <.draft_field
              field={
                %{
                  param: "floor_price",
                  label: "Floor price in #{symbol(@stock)} per token",
                  kind: :text,
                  hint: "The lowest price a bid can name."
                }
              }
              form_id="stocks-terms"
              value={@draft_values["floor_price"]}
              error={@draft_errors["floor_price"]}
            />
            <p
              :if={@floor_echo}
              id="stocks-terms-floor-echo"
              class="autolaunch-draft-hint"
              data-floor-executable={@floor_echo.executable}
            >
              Executable floor:
              <strong>{Amounts.compact_decimal(@floor_echo.executable)} {symbol(@stock)}</strong>
              per token <span :if={@floor_echo.adjusted?}>(rounded down from what you entered)</span>.
            </p>
            <Regent.Primitives.disclosure
              :if={
                @floor_echo &&
                  Amounts.compact_decimal(@floor_echo.executable) != @floor_echo.executable
              }
              id="stocks-terms-floor-exact"
              summary="Every digit of the executable floor"
            >
              <p class="autolaunch-exact-value">{@floor_echo.executable} {symbol(@stock)}</p>
            </Regent.Primitives.disclosure>
            <p :if={!@floor_echo && @draft_values["floor_price"] != ""} class="autolaunch-draft-hint">
              The exact executable floor is shown at review, from the stock token's recorded decimals.
            </p>
          </form>

          <form
            id="stocks-revenue"
            phx-change="autosave_stocks_revenue"
            phx-submit="autosave_stocks_revenue"
            class="launchpad-form-section rg-panel rg-panel--surface rg-field"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Revenue and administration</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Subject revenue and administrator</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{stage_status(@revenue_complete?)}</span>
            </header>

            <input type="hidden" name="stock_draft[subject_enabled]" value="false" />
            <label class="autolaunch-draft-field">
              <input
                type="checkbox"
                id="stocks-revenue-subject_enabled"
                name="stock_draft[subject_enabled]"
                value="true"
                checked={@subject_enabled?}
              /> Share 1.00% of stock-side pool volume with an Agent subject
            </label>
            <p class="autolaunch-draft-hint">
              Off by default. The REGENT lane of 1.00% always applies. When on, the address must be
              an Agent subject revenue address recorded by the Agent strategy.
            </p>
            <.draft_field
              :if={@subject_enabled?}
              field={
                %{
                  param: "subject_splitter",
                  label: "Subject revenue address",
                  kind: :text,
                  hint: @address_hint
                }
              }
              form_id="stocks-revenue"
              value={@draft_values["subject_splitter"]}
              error={@draft_errors["subject_splitter"]}
            />
            <.draft_field
              field={
                %{
                  param: "fee_administrator",
                  label: "Fee administrator",
                  kind: :text,
                  hint:
                    "Required. This account can later turn the subject lane on, off or point it elsewhere. It has no other power. " <>
                      @address_hint
                }
              }
              form_id="stocks-revenue"
              value={@draft_values["fee_administrator"]}
              error={@draft_errors["fee_administrator"]}
            />
          </form>

          <section id="stocks-fixed-terms" class="launchpad-form-section rg-panel rg-panel--surface">
            <header>
              <div>
                <p class="autolaunch-kicker">Fixed terms</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Every stock launch uses these</h2>
                </Regent.Structure.section_bar>
              </div>
            </header>
            <dl class="launch-wallet-terms">
              <div :for={{label, value} <- LaunchActions.terms()}>
                <dt>{label}</dt>
                <dd>{value}</dd>
              </div>
            </dl>
          </section>

          <section
            id="stocks-transactions"
            class="launchpad-form-section launchpad-transactions rg-panel rg-panel--surface"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Wallet review</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Launch transactions</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{if @launch_ready?, do: "Ready", else: "Details required"}</span>
            </header>
            <p>
              The review shows the exact start block, executable floor price, minimum raise and
              launch fee before anything is submitted. The launch fee is 100,000 REGENT, paid to
              REGENT staking as rewards and not refunded if the minimum is not raised. Your wallet
              first allows exactly that fee to be taken when it has not already, then creates the
              launch.
            </p>
            <.live_component
              :if={@launch_ready? && @draft}
              module={AutolaunchWeb.StocksLaunchWalletComponent}
              id={"autolaunch-stocks-launch-wallet-#{@draft.id}"}
              draft={@draft}
              authenticated
              active_stocks_launch={@active_stocks_launch}
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <Regent.Primitives.button :if={!@launch_ready?} type="button" disabled>
              Complete every section above
            </Regent.Primitives.button>
          </section>

          <.live_component
            :if={AutolaunchWeb.TestFundsComponent.available?()}
            module={AutolaunchWeb.TestFundsComponent}
            id="autolaunch-test-funds"
            current_human_id={@current_human_id}
            session_lease={@session_lease}
          />

          <p
            :if={@draft_notice}
            class={"autolaunch-draft-notice autolaunch-draft-notice--#{@draft_notice.tone}"}
            role={if @draft_notice.tone == :error, do: "alert", else: "status"}
          >
            {@draft_notice.message}
          </p>
        </div>

        <aside class="launchpad-create__preview rg-panel rg-support-panel" aria-label="Launch summary">
          <div>
            <p class="autolaunch-kicker">Summary</p>
            <Regent.Structure.section_bar>
              <h2 class="rg-section-bar__label">Your auction</h2>
            </Regent.Structure.section_bar>
          </div>
          <dl class="launch-wallet-terms">
            <div>
              <dt>Token</dt>
              <dd>{blank(@draft_values["name"])} · {blank(@draft_values["symbol"])}</dd>
            </div>
            <div>
              <dt>Bidders pay with</dt>
              <dd>{if @stock, do: @stock.symbol, else: blank(nil)}</dd>
            </div>
            <div>
              <dt>Bidding opens</dt>
              <dd>{blank(@draft_values["start_local"])} {@draft_values["start_timezone"]}</dd>
            </div>
            <div>
              <dt>Minimum raise</dt>
              <dd>{blank(@draft_values["minimum_raise"])} {symbol(@stock)}</dd>
            </div>
            <div>
              <dt>Floor price</dt>
              <dd>
                {if @floor_echo, do: @floor_echo.executable, else: blank(@draft_values["floor_price"])} {symbol(
                  @stock
                )}
              </dd>
            </div>
            <div>
              <dt>Subject revenue</dt>
              <dd>{if @subject_enabled?, do: "On", else: "Off"}</dd>
            </div>
          </dl>
        </aside>
      </section>
    </section>
    """
  end

  attr :field, :map, required: true
  attr :form_id, :string, required: true
  attr :value, :string, default: nil
  attr :error, :string, default: nil

  def draft_field(assigns) do
    id = "#{assigns.form_id}-#{assigns.field.param}"
    hint = assigns.field[:hint]

    described_by =
      [hint && "#{id}-hint", assigns.error && "#{id}-error"]
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> nil
        ids -> Enum.join(ids, " ")
      end

    assigns = assign(assigns, id: id, hint: hint, described_by: described_by)

    ~H"""
    <Regent.Primitives.field
      id={@id}
      label={@field.label}
      class={["autolaunch-draft-field", @field.kind == :long_text && "autolaunch-draft-field--wide"]}
    >
      <textarea
        :if={@field.kind == :long_text}
        id={@id}
        name={"stock_draft[#{@field.param}]"}
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      >{@value}</textarea>
      <input
        :if={@field.kind == :text}
        type="text"
        id={@id}
        name={"stock_draft[#{@field.param}]"}
        value={@value}
        autocomplete="off"
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      />
      <p :if={@hint} id={"#{@id}-hint"} class="autolaunch-draft-hint">{@hint}</p>
      <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error" role="alert">{@error}</p>
    </Regent.Primitives.field>
    """
  end

  # The stock as this site's lab admits it, with its recorded decimals. Without
  # a Stocks lab the decimals are only known at review, from the launchpad.
  defp stock_for(nil, _address), do: nil
  defp stock_for(_config, address) when address in [nil, ""], do: nil
  defp stock_for(config, address), do: Autolaunch.Stocks.Lab.stock(config, address)

  defp floor_echo(_value, nil), do: nil

  defp floor_echo(value, stock) do
    case Amounts.cca_price(value, stock.decimals, @new_decimals) do
      {:ok, evidence} ->
        executable = evidence.candidate_price_q96 - rem(evidence.candidate_price_q96, 100)

        if executable >= Integer.pow(2, 32) + 1 do
          %{
            executable: Amounts.format_cca_price(executable, stock.decimals, @new_decimals),
            adjusted?: evidence.adjustment_required or executable != evidence.candidate_price_q96
          }
        end

      {:error, _reason} ->
        nil
    end
  end

  defp symbol(nil), do: "the stock token"
  defp symbol(%{symbol: symbol}), do: symbol

  defp blank(value) when value in [nil, ""], do: "—"
  defp blank(value), do: value

  defp stage_status(true), do: "Complete"
  defp stage_status(_incomplete), do: "In progress"
end
