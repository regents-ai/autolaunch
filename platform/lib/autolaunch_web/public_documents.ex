defmodule AutolaunchWeb.PublicDocuments do
  @moduledoc """
  The pages Autolaunch publishes to people and to agents at the same address.

  Each document is committed Markdown beside this module: an agent that asks for
  `text/markdown` receives it as written, and the page shows the same words as
  HTML. Only these database-free documents are answered before the router;
  every other address reaches it with its own sessions and policies.
  """

  alias Autolaunch.LaunchActions, as: RevstakeLaunchActions
  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.LaunchActions
  alias AutolaunchWeb.{AgentGuides, Capabilities, Paths, ToolManifest}
  alias AutolaunchWeb.Components.AutolaunchHelpers

  @directory Path.join(__DIR__, "public_documents")
  @names ~w(home docs about changelog privacy terms llms llms-full agents skill)
  for name <- @names, do: @external_resource(Path.join(@directory, name <> ".md"))
  @sources Map.new(@names, &{&1, File.read!(Path.join(@directory, &1 <> ".md"))})
  # The About page's Key facts, repeated in llms.txt so AI tools read the same facts.
  [_about, facts] = String.split(@sources["about"], "\n## Key facts\n")
  @key_facts "## Key facts\n" <> String.trim_trailing(hd(String.split(facts, "\n## ", parts: 2)))
  @paths %{
    "/" => "home",
    "/docs" => "docs",
    "/about" => "about",
    "/changelog" => "changelog",
    "/privacy" => "privacy",
    "/terms" => "terms"
  }

  @contract_path Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @external_resource @contract_path
  @contract YamlElixir.read_from_file!(@contract_path)
  # Covered calls' routes and their components, added only while the site offers them.
  @covered_calls_contract_path Path.expand(
                                 "../../contracts/covered-calls.openapiv3.yaml",
                                 __DIR__
                               )
  @external_resource @covered_calls_contract_path
  @covered_calls_contract YamlElixir.read_from_file!(@covered_calls_contract_path)

  # Covered calls, in the agent guides only while the site offers them.
  @covered_calls_path Path.join(@directory, "covered_calls.md")
  @external_resource @covered_calls_path
  @covered_calls File.read!(@covered_calls_path)

  # Exposure's routes and their components, and its section of the agent
  # guides, added only while the site offers it.
  @exposure_contract_path Path.expand("../../contracts/exposure.openapiv3.yaml", __DIR__)
  @external_resource @exposure_contract_path
  @exposure_contract YamlElixir.read_from_file!(@exposure_contract_path)
  @exposure_guide_path Path.join(@directory, "exposure.md")
  @external_resource @exposure_guide_path
  @exposure_guide File.read!(@exposure_guide_path)

  # Earn's routes and their components, and its section of the agent guides,
  # added only while the site offers it.
  @earn_contract_path Path.expand("../../contracts/earn.openapiv3.yaml", __DIR__)
  @external_resource @earn_contract_path
  @earn_contract YamlElixir.read_from_file!(@earn_contract_path)
  @earn_guide_path Path.join(@directory, "earn.md")
  @external_resource @earn_guide_path
  @earn_guide File.read!(@earn_guide_path)

  # Agent bids' routes and their components, and their section of the agent
  # guides, added only while the site offers them.
  @agent_bids_contract_path Path.expand("../../contracts/agent-bids.openapiv3.yaml", __DIR__)
  @external_resource @agent_bids_contract_path
  @agent_bids_contract YamlElixir.read_from_file!(@agent_bids_contract_path)
  @agent_bids_guide_path Path.join(@directory, "agent_bids.md")
  @external_resource @agent_bids_guide_path
  @agent_bids_guide File.read!(@agent_bids_guide_path)

  # Agent Robinhood bids' routes and their components, and their section of
  # the agent guides, added only while the site offers them.
  @agent_robinhood_bids_contract_path Path.expand(
                                        "../../contracts/agent-robinhood-bids.openapiv3.yaml",
                                        __DIR__
                                      )
  @external_resource @agent_robinhood_bids_contract_path
  @agent_robinhood_bids_contract YamlElixir.read_from_file!(@agent_robinhood_bids_contract_path)
  @agent_robinhood_bids_guide_path Path.join(@directory, "agent_robinhood_bids.md")
  @external_resource @agent_robinhood_bids_guide_path
  @agent_robinhood_bids_guide File.read!(@agent_robinhood_bids_guide_path)

  # Agent launches' route and its components, and its section of the agent
  # guides, added only while the site offers them.
  @agent_launches_contract_path Path.expand(
                                  "../../contracts/agent-launches.openapiv3.yaml",
                                  __DIR__
                                )
  @external_resource @agent_launches_contract_path
  @agent_launches_contract YamlElixir.read_from_file!(@agent_launches_contract_path)
  @agent_launches_guide_path Path.join(@directory, "agent_launches.md")
  @external_resource @agent_launches_guide_path
  @agent_launches_guide File.read!(@agent_launches_guide_path)

  # Agent finishes' route and its components, and its section of the agent
  # guides, added only while the site offers them.
  @agent_finish_contract_path Path.expand("../../contracts/agent-finish.openapiv3.yaml", __DIR__)
  @external_resource @agent_finish_contract_path
  @agent_finish_contract YamlElixir.read_from_file!(@agent_finish_contract_path)
  @agent_finish_guide_path Path.join(@directory, "agent_finish.md")
  @external_resource @agent_finish_guide_path
  @agent_finish_guide File.read!(@agent_finish_guide_path)

  # Agent staking's route and its components, and its section of the agent
  # guides, added only while the site offers it.
  @agent_stake_contract_path Path.expand("../../contracts/agent-stake.openapiv3.yaml", __DIR__)
  @external_resource @agent_stake_contract_path
  @agent_stake_contract YamlElixir.read_from_file!(@agent_stake_contract_path)
  @agent_stake_guide_path Path.join(@directory, "agent_stake.md")
  @external_resource @agent_stake_guide_path
  @agent_stake_guide File.read!(@agent_stake_guide_path)

  # A section's title, from its own heading.
  section = fn guide -> hd(Regex.run(~r/^## (.+)$/m, guide, capture: :all_but_first)) end

  # What both agent bid features prepare, each on its own chain.
  @bid_for "a bid on a %{chains} auction, and its return and claim"
  @bid_of "a bid on a %{chains} auction, and of its return and claim"

  # Each agent feature that prepares a person's wallet steps, in the order the
  # guides hold their sections: the switch it follows
  # (`ToolManifest.features/0`), which also names its section's marker in the
  # guides (`{{agent_bids}}`), that section and its title, and how the guides'
  # sentences on who does what name it while it is on (`agent_sentences/2`).
  #
  # `for` is what its steps are for ("For a bid on a Base auction, and its
  # return and claim, a paired agent prepares the steps"), `step` what it
  # prepares while it is the only feature on, and `of` what that is of ("the
  # steps of a bid on a Base auction, and of its return and claim"). Features
  # that prepare the same thing on different chains are named once, their
  # `chain`s joined (`%{chains}`). `takes` are the words it takes out of the
  # guides' lists of what stays with the person, and `stays` how a guide names
  # its operations, when at all, while it is off and another feature is on.
  @agent_steps [
    %{
      feature: "agent_bids",
      guide: @agent_bids_guide,
      section: section.(@agent_bids_guide),
      chain: "Base",
      for: @bid_for,
      step: "the steps",
      of: @bid_of,
      takes: ["bidding", "settlement", "bid"],
      stays: "%{chains} bids"
    },
    %{
      feature: "agent_robinhood_bids",
      guide: @agent_robinhood_bids_guide,
      section: section.(@agent_robinhood_bids_guide),
      chain: "Robinhood Chain",
      for: @bid_for,
      step: "the steps",
      of: @bid_of,
      takes: ["bidding", "settlement", "bid"],
      stays: "%{chains} bids"
    },
    %{
      feature: "agent_launches",
      guide: @agent_launches_guide,
      section: section.(@agent_launches_guide),
      chain: nil,
      for: "the launch of the person's saved draft",
      step: "the launch step",
      of: "the person's saved draft",
      takes: ["launch submission", "launch"],
      stays: "the person's launches"
    },
    %{
      feature: "agent_finish",
      guide: @agent_finish_guide,
      section: section.(@agent_finish_guide),
      chain: nil,
      for: "the finish of an ended auction",
      step: "the finish step",
      of: "an ended auction",
      takes: [],
      stays: nil
    },
    %{
      feature: "agent_staking",
      guide: @agent_stake_guide,
      section: section.(@agent_stake_guide),
      chain: nil,
      for: "a stake, unstake or claim on a listed token",
      step: "the steps",
      of: "a stake, unstake or claim on a listed token",
      takes: ["staking", "claims"],
      stays: nil
    }
  ]

  # What stays with the person, before the features on take their words out:
  # the signed agent guide's list, and the browser guide's list of controls
  # while a feature is on.
  @person_controlled [
    "Wallet signing",
    "launch submission",
    "bidding",
    "settlement",
    "trading",
    "staking",
    "claims",
    "treasury verification"
  ]
  @person_controls ["Wallet", "bid", "launch"]

  # The guides' sentences on the person's launch of a draft an agent filled in,
  # each as it reads without agent launches, as before them, and while the
  # site offers them, as `launching/1` words them.
  @launching [
    {"{{launching_draft}}",
     "Your person then opens the create page, sees every field you set marked at the top of the form, and signs the launch.",
     "Your person then opens the create page, sees every field you set marked at the top of the form, and signs the launch, or you prepare its launch step for their own wallet to sign and send (see Agent launches)."},
    {"{{launching_skill}}", "your person\nsees every field you set on the create page and signs.",
     "your person\nsees every field you set on the create page and signs, or you prepare the launch step for\ntheir own wallet to sign (see Agent launches)."}
  ]

  @needs %{
    "none" => "Nothing",
    "siwa" => "Per-request SIWA proof",
    "siwa_and_pairing" => "Per-request SIWA proof and current pairing",
    "session" => "The person's sign-in",
    "wallet_signed" => "The person's sign-in and their wallet's confirmation"
  }

  # Who may run an operation on a surface that offers it, by its authority, as
  # the Agent access table says it.
  @who %{"public" => "Yes", "signed_agent" => "Signed agent", "paired_agent" => "Paired agent"}

  @description "Bid in token auctions where everyone pays the same price, then stake to earn stablecoins or onchain stocks."

  @site_name "Autolaunch"

  # The regents-cli release every public document names: the one these guides
  # were checked against, its source commit and its published wheel.
  @regents_cli %{
    version: "1.10.33",
    commit: "c12d8563c46e8b5229e32db76c1a104fb469b7b7",
    wheel_sha256: "ceb6e1abc197da4517dfcfa6c9fee0681e4d775c0f07a2b9c5562087797a89a2"
  }

  # Where security reports go, as the About page publishes it.
  @security_contact "mailto:build@regents.sh"

  # The documents and the site's fixed pages change only with a release, so the
  # release time is when each last changed.
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  # The browser-tab title and search description of every page, kept in one
  # place. A title names the page alone; `metadata/3` adds the site name once.
  @pages %{
    "/" => {"#{@site_name} · Back AI agents at a fair price", @description},
    "/create" =>
      {"Create Memestock",
       "Pair a new memecoin with a real stock and open its auction on Autolaunch."},
    "/agent-business" =>
      {"Create Revstake",
       "Tokenize a stablecoin-earning service or agent on Base and open its auction."},
    "/auctions" =>
      {"Auctions", "Every Revstake and Memestock auction on Autolaunch, live and graduated."},
    :auction =>
      {"auction", "An Autolaunch auction on Base: its price, its bids and its time left."},
    :robinhood_auction =>
      {"auction",
       "An Autolaunch auction on Robinhood Chain: its price, its bids and its time left."},
    "/tokens" =>
      {"Tokens", "Every token launched through Autolaunch, on Base and Robinhood Chain."},
    :token => {"token", "A token launched through Autolaunch on Base, to trade and stake."},
    :robinhood_token =>
      {"token", "A token launched through Autolaunch on Robinhood Chain, to trade and stake."},
    "/how-it-works" =>
      {"How it works",
       "How the auction works, and the supply, trading fees and staking rewards for every Autolaunch token."},
    "/stocks" =>
      {"Onchain Stocks",
       "Stocks next in line to pair with a Memestock token on Base and Robinhood Chain, and every stock you can pair with today."},
    :stock =>
      {"stock",
       "One stock on Base or Robinhood Chain: its onchain token, price feed and trading pools, from dated research."},
    "/animations" => {"Motion lab", "Every motion Autolaunch uses, side by side."},
    "/portfolio" => {"Portfolio", "Your Autolaunch bids, tokens and stakes in one place."},
    "/stock/covered-call" =>
      {"Covered calls",
       "List covered calls on a Base stock token and be paid the premium when a buyer buys, or buy them, in USDC."},
    "/stock/isolated-afters" =>
      {"Isolated Exposure to After-hours Stocks",
       "Split a Base stock token into two for a week: one carries its moves while the market is closed, the other while it is open."},
    "/earn" =>
      {"Earn",
       "Lend USDC on Base through Aave from your own wallet, see your balance grow, and withdraw it when you choose."},
    :bid =>
      {"Your bid",
       "One of your Autolaunch bids: what is yours, what comes next and what it cost."},
    "/account" => {"Account", "Your Autolaunch sign-in, wallet and connected accounts."},
    "/account/agents" => {"Agents", "The agents you paired, and pairing a new one."},
    "/account/points" => {"Points", "Your points and activity."},
    "/pair" =>
      {"Pair New Agent",
       "Pair your agent with your account, and send it to the page you came from."},
    "/regent" =>
      {"REGENT",
       "$REGENT is the value token for all Regents Labs products. Stake it to earn USDC and REGENT."},
    "/convert" =>
      {"REGENT Fees",
       "REGENT's share of trading fees waiting in each graduated Memestock launch."},
    "/docs" =>
      {"Developer guide",
       "Read Autolaunch auctions, tokens, bid estimates and treasury reports over HTTP or WebMCP, without an account or API key."},
    "/about" =>
      {"About",
       "What Autolaunch does, how it differs, who uses it, the team behind it, key facts, common questions and how to reach us."},
    "/changelog" =>
      {"Changelog", "What changed on autolaunch.sh for people and agents, newest first."},
    "/privacy" =>
      {"Privacy",
       "What Autolaunch keeps about visitors and people who sign in, what becomes public on the chain, and how to ask for removal."},
    "/terms" => {"Terms of Use", "The terms that apply when you use Autolaunch."},
    "/blog" => {"Blog", "Latest updates from Autolaunch."},
    :missing_post => {"Post not found", "There is no Autolaunch blog post at this address."},
    "/unavailable" => {"Not available in your region", "This page isn’t offered where you are."}
  }

  # The fixed pages both sitemaps list.
  @sitemap_pages ~w(/ /auctions /tokens /stocks /how-it-works /regent /docs /about /changelog /privacy /terms /blog)

  @doc "The public document at `path` as `%{markdown: text}`, or nil for every other address."
  def document("/agents" <> _rest = path), do: AgentGuides.document(path)

  def document("/stocks/" <> symbol) do
    case Autolaunch.Stocks.UpcomingCatalog.stock(symbol) do
      nil -> nil
      {stock, chain} -> %{markdown: AutolaunchWeb.StockMarkdown.render(stock, chain)}
    end
  end

  def document(path) do
    case @paths do
      %{^path => name} -> %{markdown: markdown(name)}
      _other -> nil
    end
  end

  @doc "The short agent index served at `/llms.txt`: what Autolaunch is, first steps and links."
  def agent_guide, do: markdown("llms")

  @doc "The whole agent guide in one file, served at `/llms-full.txt`."
  def full_agent_guide, do: markdown("llms-full")

  @doc "The regents-cli release every public document names."
  def regents_cli_version, do: @regents_cli.version

  @doc "Every public document's name, for reading them all."
  def names, do: @names
  @doc "The install, sign-in and pairing guide served at `/agents.md`."
  def signed_agent_guide, do: markdown("agents")

  @doc "The skill served at `/skill.md`: using Autolaunch for your person."
  def skill_guide, do: markdown("skill")

  @doc "The browser tool manifest served at `/capabilities.json`: every tool the pages register."
  def capabilities do
    commit = Application.fetch_env!(:autolaunch, :source_commit)

    Map.put(ToolManifest.current(), "build", %{
      release: String.slice(commit, 0, 7),
      commit: commit
    })
  end

  @doc "Whether the page at `path` also answers as Markdown."
  def markdown?("/stocks/" <> symbol),
    do: Autolaunch.Stocks.UpcomingCatalog.stock(symbol) != nil

  def markdown?(path), do: Map.has_key?(@paths, path) or path in AgentGuides.paths()

  @doc """
  The `page_title` and `page_description` assigns the root layout reads. Every
  page that renders in the root layout assigns them from here.
  """
  def page(key) do
    {title, description} = title_and_description(key)
    [page_title: title, page_description: description]
  end

  @doc "The page's title alone, as the `about` and `docs` reads give it."
  def title(key), do: key |> title_and_description() |> elem(0)

  defp title_and_description(key) do
    if key in AgentGuides.paths(), do: AgentGuides.page(key), else: Map.fetch!(@pages, key)
  end

  @doc """
  The assigns of an auction's or a token's page, the title naming its token,
  as in "First Bite (BITE) auction", or "SANDY token" when the name is the ticker.
  """
  def market_page(key, name, ticker) do
    {kind, description} = Map.fetch!(@pages, key)
    named = if AutolaunchHelpers.same_name?(name, ticker), do: name, else: "#{name} (#{ticker})"
    [page_title: "#{named} #{kind}", page_description: description]
  end

  @doc "The page's full browser title, the suffix that adds the site name, and its description."
  def metadata(path, title, description) do
    suffix = if path == "/", do: "", else: " · #{@site_name}"
    %{title: title <> suffix, suffix: suffix, description: description}
  end

  @doc "An address on this site, absolute."
  def url(path), do: AutolaunchWeb.Endpoint.url() <> path

  # A table keeps its roles when a phone shows its rows as cards, and the only
  # spans are the cells' column names (`label_cells/1`), which a screen reader
  # already has.
  @sanitize [
    tags: ~w(h1 h2 h3 p ul ol li strong em a code pre br table thead tbody tr th td span),
    tag_attributes: %{"a" => ["href"]},
    generic_attributes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "noopener noreferrer",
    set_tag_attribute_values: %{
      "table" => %{"role" => "table"},
      "thead" => %{"role" => "rowgroup"},
      "tbody" => %{"role" => "rowgroup"},
      "tr" => %{"role" => "row"},
      "th" => %{"role" => "columnheader"},
      "td" => %{"role" => "cell"},
      "span" => %{"aria-hidden" => "true"}
    }
  ]
  @markdown [extension: [table: true, inline_code_attributes: false]]

  @doc """
  A document's committed Markdown as sanitized HTML. On a wide screen a table
  sits in a box that scrolls sideways and can be reached from the keyboard to
  scroll it; under 768px each of its rows stands as a card (`facts.css`).
  """
  # The HTML is MDEx-sanitized from the committed public Markdown.
  # sobelow_skip ["XSS.Raw"]
  def html(markdown) do
    markdown
    |> MDEx.parse_document!(@markdown)
    |> MDEx.traverse_and_update(&label_cells/1)
    |> MDEx.to_html!(@markdown ++ [sanitize: @sanitize])
    |> String.replace(
      ~s(<table role="table">),
      ~s(<div class="document-table" role="region" aria-label="Table" tabindex="0"><table role="table">)
    )
    |> String.replace("</table>", "</table></div>")
    |> Phoenix.HTML.raw()
  end

  # Every cell starts with its column's name, shown only when the rows stand as cards.
  defp label_cells(%MDEx.Table{nodes: [%MDEx.TableRow{nodes: heads} = head | rows]} = table) do
    labels = Enum.map(heads, &cell_label/1)
    %{table | nodes: [head | Enum.map(rows, &label_row(&1, labels))]}
  end

  defp label_cells(node), do: node

  defp label_row(%MDEx.TableRow{nodes: cells} = row, labels),
    do: %{row | nodes: Enum.zip_with(cells, labels, &%{&1 | nodes: [&2 | &1.nodes]})}

  defp cell_label(%MDEx.TableCell{nodes: nodes}) do
    text = Enum.map_join(nodes, &Map.get(&1, :literal, ""))

    %MDEx.Raw{
      literal:
        "<span>#{text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}</span>"
    }
  end

  @doc "Where an agent that reached a missing or refused address can go instead."
  def recovery_links do
    [
      {"Home", url("/")},
      {"Developer guide", url("/docs")},
      {"OpenAPI description", url("/openapi.json")},
      {"Agent guide", url("/llms.txt")},
      {"Sitemap", url("/sitemap.xml")}
    ]
  end

  @doc "The public API description, with this site's address as its server."
  def openapi do
    contract()
    |> Map.put("servers", [%{"url" => url("")}])
    |> Map.put("externalDocs", %{
      "url" => url("/docs"),
      "description" =>
        "Developer guide: errors, rate limits, and the versioning and deprecation policy"
    })
    |> put_in(["info", "termsOfService"], url("/terms"))
  end

  @doc """
  Every public page with the time it last changed: the fixed pages, each
  stock's page, then each listed auction and token, newest first. A fixed page last changed with the
  release; the auction and token lists also change when a listed record does.
  """
  def sitemap do
    auctions =
      Enum.map(Autolaunch.sitemap_auctions!(actor: nil), &{Paths.auction_url(&1), &1.updated_at})

    tokens =
      Enum.map(
        Autolaunch.sitemap_tokens!(actor: nil),
        &{Paths.token_url(&1.auction), &1.updated_at}
      )

    fixed =
      Enum.map(
        sitemap_pages(),
        fn
          "/auctions" = path -> {url(path), latest(auctions)}
          "/tokens" = path -> {url(path), latest(tokens)}
          path -> {url(path), @released_at}
        end
      )

    stocks =
      Enum.map(
        Autolaunch.Stocks.UpcomingCatalog.stocks(),
        &{url("/stocks/" <> URI.encode(&1["symbol"])), @released_at}
      )

    entries =
      Enum.map_join(fixed ++ stocks ++ auctions ++ tokens, "\n", fn {location, changed} ->
        "  <url><loc>#{escape(location)}</loc><lastmod>#{DateTime.to_iso8601(changed)}</lastmod></url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{entries}
    </urlset>
    """
  end

  @agent_documents [
    {"/llms.txt", "Agent index",
     "What Autolaunch is, first steps for an agent, and where to read on."},
    {"/llms-full.txt", "Whole agent guide",
     "The auction, both launch types, fees, staking, REGENT and every agent route in one file."},
    {"/agents.md", "Signed agent guide",
     "Install regents-cli, sign in, pair with a person and fill in a launch draft."},
    {"/skill.md", "Skill", "Using Autolaunch for a person, from research to watching a bid."},
    {"/openapi.json", "OpenAPI description", "Every public route, its inputs and its answers."},
    {"/capabilities.json", "Tool manifest", "Every WebMCP tool the pages register, as JSON."},
    {"/.well-known/api-catalog", "API catalog", "RFC 9727 discovery for the API."}
  ]

  @doc """
  The Markdown sitemap served at `/sitemap.md`: every fixed page and agent
  document with what it is for. Each auction and token page is in
  `/sitemap.xml`.
  """
  def markdown_sitemap do
    pages =
      Enum.map_join(sitemap_pages(), "\n", fn path ->
        {title, description} = title_and_description(path)
        "- [#{title}](#{url(path)}) | Summary: #{description}"
      end)

    documents =
      Enum.map_join(@agent_documents, "\n", fn {path, title, description} ->
        "- [#{title}](#{url(path)}) | Summary: #{description}"
      end)

    """
    # Autolaunch sitemap

    Every page on #{url("")}, with what it is for. Each auction and token has a page
    of its own too; they are listed in the [XML sitemap](#{url("/sitemap.xml")}).
    Last changed #{Date.to_iso8601(DateTime.to_date(@released_at))}.

    ## Pages

    #{pages}

    ## For agents

    #{documents}
    """
  end

  @doc "The RFC 9116 security contact file; it expires a year after the release."
  def security_txt do
    """
    Contact: #{@security_contact}
    Expires: #{@released_at |> DateTime.shift(year: 1) |> DateTime.to_iso8601()}
    Preferred-Languages: en
    Canonical: #{url("/.well-known/security.txt")}
    Policy: #{url("/about")}
    """
  end

  @doc "The RFC 9727 API catalog: a linkset naming the API, its description and its documentation."
  def api_catalog do
    %{
      "linkset" => [
        %{
          "anchor" => url("/api/v1"),
          "service-desc" => [%{"href" => url("/openapi.json"), "type" => "application/json"}],
          "service-doc" => [
            %{"href" => url("/docs"), "type" => "text/html"},
            %{"href" => url("/llms-full.txt"), "type" => "text/plain"}
          ]
        }
      ]
    }
  end

  @doc "Who Autolaunch is, for a reader that speaks schema.org."
  def structured_data do
    %{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "WebApplication",
          "@id" => url("/#application"),
          "name" => "Autolaunch",
          "url" => url("/"),
          "description" => @description,
          "applicationCategory" => "FinanceApplication",
          "operatingSystem" => "Web",
          "image" => url("/images/og-image.png"),
          "sameAs" => ["https://github.com/regents-ai/autolaunch"],
          "publisher" => %{"@id" => "https://regents.sh/#organization"}
        },
        %{
          "@type" => "WebSite",
          "@id" => url("/#website"),
          "name" => "Autolaunch",
          "url" => url("/"),
          "description" => @description,
          "publisher" => %{"@id" => "https://regents.sh/#organization"}
        },
        %{
          "@type" => "Organization",
          "@id" => "https://regents.sh/#organization",
          "name" => "Regents Labs",
          "legalName" => "Regents Labs, Inc.",
          "url" => "https://regents.sh/",
          "sameAs" => ["https://github.com/regents-ai", "https://x.com/regents_sh"],
          "contactPoint" => [
            %{
              "@type" => "ContactPoint",
              "contactType" => "customer support",
              "email" => "build@regents.sh",
              "url" => url("/about"),
              "availableLanguage" => "English"
            },
            %{
              "@type" => "ContactPoint",
              "contactType" => "security",
              "email" => "build@regents.sh"
            },
            %{
              "@type" => "ContactPoint",
              "contactType" => "privacy",
              "email" => "privacy@regents.sh"
            }
          ]
        }
      ]
    }
  end

  @doc """
  The structured data of an auction's page: the page, and the auction it is
  about as an online event that opens and closes, named by its contract on
  its chain. `page` is the page's details from `AutolaunchWeb.ShareCard.meta/1`.
  """
  def auction_data(auction, page) do
    record_data(page, %{
      "@type" => "Event",
      "@id" => page.url <> "#auction",
      "name" => "#{auction.title} (#{auction.token_symbol}) auction",
      "url" => page.url,
      "description" => auction.summary || page.description,
      "image" => page.image,
      "startDate" => iso8601(auction.opened_at),
      "endDate" => iso8601(auction.estimated_end_at),
      "eventAttendanceMode" => "https://schema.org/OnlineEventAttendanceMode",
      "location" => %{"@type" => "VirtualLocation", "url" => page.url},
      "identifier" => caip10(auction.chain_id, auction.auction_address)
    })
  end

  @doc """
  The structured data of a token's page: the page, and the token it is about,
  named by its contract on its chain. `page` is the page's details from
  `AutolaunchWeb.ShareCard.token_meta/2`.
  """
  def token_data(auction, page) do
    record_data(page, %{
      "@type" => "FinancialProduct",
      "@id" => page.url <> "#token",
      "name" => auction.title,
      "alternateName" => auction.token_symbol,
      "url" => page.url,
      "description" => auction.summary || page.description,
      "image" => page.image,
      "category" => if(auction.kind == :agent, do: "Revstake token", else: "Memestock token"),
      "identifier" => caip10(auction.chain_id, auction.token_address)
    })
  end

  # The page, about one auction or token, and where the public API gives its record.
  defp record_data(page, entity) do
    entity =
      entity
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.put("subjectOf", %{
        "@type" => "DataDownload",
        "contentUrl" => page.record,
        "encodingFormat" => "application/json"
      })

    %{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "WebPage",
          "@id" => page.url,
          "url" => page.url,
          "name" => page.title,
          "description" => page.description,
          "isPartOf" => %{"@id" => url("/#website")},
          "mainEntity" => %{"@id" => entity["@id"]}
        },
        entity
      ]
    }
  end

  # A contract named the CAIP-10 way: its chain and its address.
  defp caip10(_chain_id, nil), do: nil
  defp caip10(chain_id, address), do: "eip155:#{chain_id}:#{address}"

  defp iso8601(nil), do: nil
  defp iso8601(at), do: DateTime.to_iso8601(at)

  # The `{{claude_connector}}` line and its blank line become the Claude
  # connector's paragraph only while it is on; `{{hosted_mcp}}` says what the
  # hosted MCP address serves now, naming Claude's connector while it is on;
  # `{{doors}}` is the Agent access table of what is offered now.
  defp markdown(name) do
    connector? = Autolaunch.OAuth.enabled?()
    on = ToolManifest.features()

    @sources[name]
    |> String.replace("{{claude_connector}}\n\n", claude_connector(connector?))
    |> String.replace("{{hosted_mcp}}", hosted_mcp(connector?))
    |> String.replace("{{doors}}", door_table(connector?))
    |> String.replace("{{key_facts}}", @key_facts)
    |> String.replace("{{covered_calls}}\n", covered_calls())
    |> String.replace("{{exposure}}\n", exposure())
    |> String.replace("{{earn}}\n", earn())
    |> agent_sections(on)
    |> agent_sentences(on)
    |> launching()
    |> String.replace("{{tools}}", tool_table())
    |> String.replace("{{origin}}", url(""))
    |> String.replace("{{regents_cli}}", @regents_cli.version)
    |> String.replace("{{regents_cli_commit}}", @regents_cli.commit)
    |> String.replace("{{regents_cli_wheel_sha256}}", @regents_cli.wheel_sha256)
    |> String.replace("{{read_only}}", read_only_now())
    |> String.replace("{{memestock_launchpad}}", memestock_launchpad())
    |> durations()
  end

  # How long a new launch's auction runs and how a new Memestock creator's
  # tokens are released, in words, from the launches' fixed schedules, as the
  # pages say it.
  defp durations(markdown) do
    Enum.reduce(
      [
        {"{{revstake_auction}}",
         LaunchChain.time_estimate(:base, RevstakeLaunchActions.schedule().length)},
        {"{{memestock_auction_base}}",
         LaunchChain.time_estimate(:base, LaunchActions.schedule(:base).length)},
        {"{{memestock_auction_robinhood}}",
         LaunchChain.time_estimate(:robinhood, LaunchActions.schedule(:robinhood).length)},
        {"{{memestock_release_base}}", LaunchActions.release(:base)},
        {"{{memestock_release_robinhood}}", LaunchActions.release(:robinhood)}
      ],
      markdown,
      fn {mark, words}, text -> String.replace(text, mark, words) end
    )
  end

  # Every tool the pages register now (`AutolaunchWeb.ToolManifest`).
  defp tool_table do
    """
    | Tool | Where | Needs | What it does |
    | --- | --- | --- | --- |
    #{Enum.map_join(ToolManifest.tools(), "\n", &"| `#{&1["name"]}` | #{if &1["scope"] == "site", do: "Every page", else: &1["scope"]} | #{Map.fetch!(@needs, &1["requires"])} | #{&1["description"]} |")}\
    """
  end

  defp covered_calls do
    if "covered_calls" in ToolManifest.features(),
      do: String.replace(@covered_calls, "{{covered_call_markets}}", covered_call_markets()),
      else: ""
  end

  # Each stock the site offers covered calls on, named by its issuer, its chain
  # and its exact addresses; nothing while their description can't be read.
  defp covered_call_markets do
    case Autolaunch.CoveredCalls.Deployment.current() do
      {:ok, %{markets: markets}} ->
        rows =
          Enum.map_join(markets, "\n", fn market ->
            stock = Autolaunch.CoveredCalls.Deployment.identity(market)

            "| #{stock.symbol} | #{stock.issuer} | #{stock.chain} (#{stock.chain_id}) | `#{stock.stock}` | `#{stock.contract}` |"
          end)

        """
        | Stock | Issuer | Chain | Stock address | Contract address |
        | --- | --- | --- | --- | --- |
        #{rows}

        The issuer can pause or seize the stock token.\
        """

      {:error, _unread} ->
        ""
    end
  end

  defp exposure, do: if("exposure" in ToolManifest.features(), do: @exposure_guide, else: "")

  defp earn, do: if("earn" in ToolManifest.features(), do: @earn_guide, else: "")

  # Each agent feature's section of the guides, only while it is on.
  defp agent_sections(markdown, on) do
    Enum.reduce(@agent_steps, markdown, fn steps, text ->
      String.replace(
        text,
        "{{#{steps.feature}}}\n",
        if(steps.feature in on, do: steps.guide, else: "")
      )
    end)
  end

  # The guides' sentences on who does what (`{{bidding_…}}`), made from the
  # agent features on now: while none is, each says what stays with the
  # person, as before them; otherwise each names what a paired agent can
  # prepare for the person's own wallet to sign, points to the sections that
  # say how, and leaves out of what stays with the person every word an on
  # feature takes.
  defp agent_sentences(markdown, on) do
    said = said(Enum.split_with(@agent_steps, &(&1.feature in on)))
    Regex.replace(~r/\{\{bidding_(\w+)\}\}/, markdown, fn _mark, name -> sentence(name, said) end)
  end

  # The parts the sentences are made of. Features that prepare the same thing
  # are one item, their chains joined; `step` is the one item's own while it
  # is alone. `bids` are the bid features on, for the bid card's sentence, and
  # `stays` how the guides name the off features' operations, if at all.
  defp said({offered, others}) do
    items =
      offered
      |> Enum.chunk_by(& &1.for)
      |> Enum.map(fn [first | _] = same ->
        %{
          for: chained(same, first.for, " or "),
          steps: "#{first.step} of " <> chained(same, first.of, " or "),
          step: first.step
        }
      end)

    %{
      items: items,
      for: listed(Enum.map(items, &("for " <> &1.for))),
      steps: listed(Enum.map(items, & &1.steps)),
      step: if(match?([_one], items), do: hd(items).step, else: "the steps"),
      see: listed(Enum.map(offered, & &1.section)),
      taken: Enum.flat_map(offered, & &1.takes),
      bids: Enum.filter(offered, &(&1.for == @bid_for)),
      stays:
        others
        |> Enum.filter(& &1.stays)
        |> Enum.chunk_by(& &1.stays)
        |> Enum.map(fn [first | _] = same -> chained(same, first.stays, " and ") end)
    }
  end

  # The words of features that say the same thing on different chains, with
  # their chains joined.
  defp chained(same, words, joint),
    do: String.replace(words, "%{chains}", Enum.map_join(same, joint, & &1.chain))

  defp sentence("agents", %{items: []}),
    do:
      listed(@person_controlled) <>
        " remain person-controlled. The signed interface does not expose these operations."

  defp sentence("agents", said),
    do:
      "#{listed(@person_controlled -- said.taken)} remain person-controlled. #{up(said.for)}, " <>
        "a paired agent prepares #{said.step} through the signed interface, and the person's " <>
        "own wallet signs and sends #{each(said.step)} (see #{said.see})" <>
        stays(said, "stay on the site's pages") <> "."

  defp sentence("skill", %{items: []}),
    do:
      "Bidding, trading,\nclaiming, staking and settlement stay with your person's own wallet; " <>
        "no agent tool or command\ndoes them."

  # Its last two lines break once: inside the launch's words when they are
  # named, otherwise before the sections.
  defp sentence("skill", said) do
    for = yours(up(said.for))

    "Bidding, trading,\nclaiming, staking and settlement stay with your person's own wallet, " <>
      "which signs every step.\n#{for}, you can prepare #{said.step}" <>
      if(for =~ "\n", do: " ", else: "\n") <>
      "(see #{said.see})" <> yours(stays(said, "stay on the site's pages")) <> "."
  end

  defp sentence("card", %{bids: []}), do: "No agent command claims, withdraws or\n   bids."

  defp sentence("card", %{bids: bids}),
    do:
      "For a bid on a #{Enum.map_join(bids, " or ", & &1.chain)} auction you can\n   prepare " <>
        "its return and claim for your person's wallet to sign " <>
        "(see #{listed(Enum.map(bids, & &1.section))}); no agent\n   command claims, " <>
        "withdraws or bids by itself."

  defp sentence("tools", %{items: []}),
    do:
      "Wallet and launch controls remain person-controlled and are not registered as agent tools;"

  defp sentence("tools", said),
    do:
      "#{listed(@person_controls -- said.taken)} controls remain person-controlled; " <>
        "#{said.for}, a paired agent prepares #{said.step}, which the person's own wallet " <>
        "signs (see #{said.see});"

  defp sentence("controls", %{items: []}),
    do: "These financial and launch controls are not registered as agent tools."

  defp sentence("controls", said),
    do:
      "#{up(said.for)}, a paired agent can also prepare #{said.step} for the person's own " <>
        "wallet to sign and send ([agents.md]({{origin}}/agents.md))."

  defp sentence("wallet", %{items: []}),
    do:
      "Reads are public; bidding, launching, trading and staking need the person's own " <>
        "wallet, through the person-controlled interface."

  defp sentence("wallet", said),
    do:
      "Reads are public; bidding, launching, trading and staking need the person's own " <>
        "wallet, which signs every step. A paired agent can prepare #{said.steps}" <>
        if(said.steps =~ ", and ", do: ",", else: "") <>
        " for that wallet" <> stays(said, "go through the person-controlled interface") <> "."

  defp sentence("docs", %{items: []}),
    do:
      "Bidding, claiming, launching, trading and staking happen on the website with the " <>
        "person's own wallet, and every step asks the wallet holder to confirm, through the " <>
        "person-controlled interface."

  defp sentence("docs", said),
    do:
      "Bidding, claiming, launching, trading and staking happen with the person's own " <>
        "wallet, and every step asks the wallet holder to confirm. A paired agent can " <>
        "prepare #{said.steps} (see #{said.see})" <>
        stays(said, "happen on the website, through the person-controlled interface") <> "."

  defp sentence("website", %{items: []}),
    do:
      "These happen on the website with the person's own wallet: auctions and launches on " <>
        "https://autolaunch.sh, and REGENT staking on https://regents.sh/stake. Every step " <>
        "asks the wallet holder to confirm."

  defp sentence("website", said),
    do:
      "These happen with the person's own wallet, and every step asks the wallet holder to " <>
        "confirm. A paired agent can prepare #{said.steps} (see #{said.see}); everything " <>
        "else here happens on the website: auctions and launches on https://autolaunch.sh, " <>
        "and REGENT staking on https://regents.sh/stake."

  defp sentence("home", %{items: []}),
    do:
      "Bidding, launching and staking happen on the website with the person's own wallet; " <>
        "every step asks the wallet holder to sign."

  defp sentence("home", said),
    do:
      "Bidding, launching and staking happen with the person's own wallet; every step asks " <>
        "the wallet holder to sign. A paired agent can prepare #{said.steps} " <>
        "([agents.md]({{origin}}/agents.md)); the rest happens on the website."

  # The off features' operations a sentence names as staying with the person,
  # with what they do there; nothing when there are none.
  defp stays(%{stays: []}, _where), do: ""
  defp stays(%{stays: stays}, where), do: "; #{listed(stays)} #{where}"

  defp up("for " <> rest), do: "For " <> rest

  defp each("the steps"), do: "each one"
  defp each(_one_step), do: "it"

  # The skill speaks to the agent of its person as "your person", and names the
  # launch of their draft "your person's launch from their saved draft", its
  # line broken where the skill's lines break.
  defp yours(words) do
    words
    |> String.replace(
      "the launch of the person's saved draft",
      "your person's launch\nfrom their saved draft"
    )
    |> String.replace("the person's", "your person's")
  end

  # Names in a sentence: "A", "A and B", "A, B and C", with a comma before the
  # last "and" when a name has commas of its own, so the last reads apart.
  defp listed([]), do: ""
  defp listed([name]), do: name

  defp listed(names) do
    {first, [last]} = Enum.split(names, -1)
    joint = if Enum.any?(names, &(&1 =~ ",")), do: ", and ", else: " and "
    Enum.join(first, ", ") <> joint <> last
  end

  # Each sentence on the person's launch of a draft an agent filled in, as it
  # reads with agent launches off or on.
  defp launching(markdown) do
    on? = "agent_launches" in ToolManifest.features()

    Enum.reduce(@launching, markdown, fn {mark, off, on}, text ->
      String.replace(text, mark, if(on?, do: on, else: off))
    end)
  end

  # The fixed pages the sitemaps list, with covered calls, Exposure and Earn while the site
  # offers them.
  defp sitemap_pages do
    on = ToolManifest.features()

    @sitemap_pages ++
      if("covered_calls" in on, do: ["/stock/covered-call"], else: []) ++
      if("exposure" in on, do: ["/stock/isolated-afters"], else: []) ++
      if("earn" in on, do: ["/earn"], else: []) ++ AgentGuides.paths()
  end

  defp claude_connector(false), do: ""

  defp claude_connector(true),
    do:
      "Claude doesn't use these steps: it pairs through Autolaunch's connector, with no " <>
        "command line or key of its own. [Claude]({{origin}}/agents/claude) has the setup.\n\n"

  # What the hosted MCP address serves now: a paired agent's tools by name, and,
  # while Claude can connect, its connector and the tools a connected app has
  # as itself.
  defp hosted_mcp(connector?) do
    "Autolaunch's hosted MCP endpoint is {{origin}}/mcp. Every call there carries a paired " <>
      "agent's signature, as for a signed request. A paired agent's tools there are " <>
      names(agent_tools()) <>
      ", each with the same answers and refusals as its browser tool and route. A tool that " <>
      "prepares wallet steps is listed only once launches are open. To read without signing " <>
      "in, use the browser tools or the API." <> connector(connector?)
  end

  defp connector(false), do: ""

  defp connector(true),
    do:
      " It is also Claude's connector: the person adds it in Claude's settings, then signs " <>
        "in here when Claude asks and allows it. Claude's own tools there (" <>
        names(app_tools()) <>
        ") only keep an identity for the connection, pair it with the person's account and " <>
        "check in; once paired, Claude has a paired agent's tools too. " <>
        "[Claude]({{origin}}/agents/claude) has the setup."

  @doc """
  What the hosted MCP server tells a client before its first call: the tools a
  paired agent has there now and, while Claude can connect, how a connected
  app keeps its identity and pairs.
  """
  def mcp_instructions do
    connector? = Autolaunch.OAuth.enabled?()

    "Autolaunch, where agents and their people back long-term agents through fair token " <>
      "auctions. Every call is signed by a paired agent's own wallet" <>
      if(connector?,
        do: ", or carries the token of an app a person connected to their account here",
        else: ""
      ) <>
      ". A paired agent's tools are " <>
      Enum.join(agent_tools(), ", ") <>
      ". A tool that prepares wallet steps is listed only once launches are open. " <>
      "regents mcp signs each call for an agent. " <>
      if(connector?,
        do:
          "A connected app keeps one Regents identity: call register_identity, then " <>
            "get_identity. If it is not paired, call pair_identity with the one-use code your " <>
            "person gives you, your name and your harness, and call check_in so your person " <>
            "sees you are active. Once paired, you work here as that agent: its tools are " <>
            "yours as they are any paired agent's. ",
        else: ""
      ) <> "Never ask for a password, a private key or a wallet signature."
  end

  # The operations offered now (`AutolaunchWeb.Capabilities`): the site's own,
  # each feature's while it is on, and a connected app's while Claude can connect.
  defp offered do
    Capabilities.offered(
      ToolManifest.features() ++
        if(Autolaunch.OAuth.enabled?(), do: ["connected_apps"], else: [])
    )
  end

  # The hosted MCP tools offered now: a paired agent's, and a connected app's
  # own, by name.
  defp agent_tools,
    do:
      for(
        %{"surfaces" => %{"hosted_mcp" => true}, "hosted_tool" => name} = row <- offered(),
        row["authority"] != "connected_app",
        do: name
      )

  defp app_tools,
    do:
      for(
        %{"authority" => "connected_app", "hosted_tool" => name} <- offered(),
        do: name
      )

  # Tool names as a list in words: `a`, `b` and `c`.
  defp names(tools) do
    quoted = Enum.map(tools, &"`#{&1}`")
    Enum.join(Enum.drop(quoted, -1), ", ") <> " and " <> List.last(quoted)
  end

  # Agent access: each action offered now and what each way in offers it, with
  # Claude's column only while Claude can connect.
  defp door_table(connector?) do
    doors =
      [{"Browser", "webmcp"}, {"Hosted MCP", "hosted_mcp"}, {"API", "http"}] ++
        if(connector?, do: [{"Claude", :claude}], else: []) ++ [{"CLI", "cli"}]

    rows =
      Enum.map_join(offered(), "\n", fn row ->
        "| #{row["title"]} | " <> Enum.map_join(doors, " | ", &cell(row, elem(&1, 1))) <> " |"
      end)

    claude_doors(connector?) <>
      opens_soon(Autolaunch.Prelaunch.read_only?()) <>
      """
      | Action | #{Enum.map_join(doors, " | ", &elem(&1, 0))} |
      | --- |#{String.duplicate(" --- |", length(doors))}
      #{rows}

      The API and regents-cli answer with the route's JSON document, and the Browser tool gives that document with its status, as `{"ok", "status", "body"}`. The Hosted MCP tool gives the document's `data`. A paged list gives its whole page instead: its entries, the cursor for the next page, and `robinhood_unavailable`, which says whether Robinhood could be read just now. One auction comes whole too, with that same flag. Points gives its whole document, which has no `data`. A refusal is the same `{"error": {"code", "message", "hint"}}` on every way in.\
      """
  end

  defp claude_doors(false), do: ""

  defp claude_doors(true),
    do:
      "Claude is the connector a person adds in Claude's settings. Connected app means an " <>
        "app connected that way, which keeps its own identity and pairing. Once paired means " <>
        "Claude can use the tool after its person pairs it.\n\n"

  defp opens_soon(false), do: ""

  defp opens_soon(true),
    do: "Opens soon means that way in offers the action once Autolaunch opens.\n\n"

  # While read-only mode is on, an action whose route waits for Autolaunch to
  # open (`AutolaunchWeb.Prelaunch.open?/2`) opens soon on every way in that
  # offers it: its tools and commands call that route, and its hosted tool waits
  # too.
  defp cell(row, door) do
    case door(row, door) do
      "No" -> "No"
      who -> if waits?(row), do: "Opens soon", else: who
    end
  end

  defp waits?(%{"route" => route}) do
    [method, path] = String.split(route, " ")

    Autolaunch.Prelaunch.read_only?() and
      not AutolaunchWeb.Prelaunch.open?(method, String.split(path, "/", trim: true))
  end

  defp waits?(_hosted_only), do: false

  # A connected app runs its own tools on the hosted MCP server, and Claude, as
  # one, runs a paired agent's there once its person pairs it; every other call
  # there is a paired agent's.
  defp door(%{"authority" => "connected_app"}, "hosted_mcp"), do: "Connected app"
  defp door(%{"surfaces" => %{"hosted_mcp" => true}}, "hosted_mcp"), do: "Paired agent"
  defp door(%{"authority" => "connected_app"}, :claude), do: "Yes"
  defp door(%{"surfaces" => %{"hosted_mcp" => true}}, :claude), do: "Once paired"
  defp door(_row, :claude), do: "No"

  defp door(%{"authority" => authority, "surfaces" => surfaces}, surface),
    do: if(surfaces[surface] == true, do: Map.fetch!(@who, authority), else: "No")

  # The contract as the site offers it now: with every feature switched off it is
  # api-contract.openapiv3.yaml exactly; each feature that is on adds its paths
  # and components.
  defp contract do
    on = ToolManifest.features()

    [
      {"covered_calls", @covered_calls_contract},
      {"exposure", @exposure_contract},
      {"earn", @earn_contract},
      {"agent_bids", @agent_bids_contract},
      {"agent_robinhood_bids", @agent_robinhood_bids_contract},
      {"agent_launches", @agent_launches_contract},
      {"agent_finish", @agent_finish_contract},
      {"agent_staking", @agent_stake_contract}
    ]
    |> Enum.filter(fn {feature, _added} -> feature in on end)
    |> Enum.reduce(@contract, fn {_feature, added}, contract ->
      contract
      |> Map.update!("paths", &Map.merge(&1, added["paths"]))
      |> Map.update!("components", &join_components(&1, added["components"]))
    end)
  end

  # Each kind of component (schemas, parameters) with the added ones beside its own.
  defp join_components(ours, added),
    do: Map.merge(ours, added, fn _kind, own, more -> Map.merge(own, more) end)

  # The Base Memestock launchpad an agent sends its own launch to.
  defp memestock_launchpad,
    do: "`#{Autolaunch.Stocks.Lab.address!(Autolaunch.Stocks.Lab.current!(), :launchpad)}`"

  # The prelaunch gate as it stands on this deployment right now.
  defp read_only_now do
    if Autolaunch.Prelaunch.read_only?(),
      do:
        "Read-only mode is on right now: pairing and private reads work, but metadata saves return `prelaunch_read_only` and the create pages are closed.",
      else: "Read-only mode is off right now: metadata saves and the create pages are open."
  end

  # A list page last changed with the release or with its newest listed record.
  defp latest(entries),
    do: Enum.max([@released_at | Enum.map(entries, &elem(&1, 1))], DateTime)

  defp escape(text),
    do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
