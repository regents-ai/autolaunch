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
  alias AutolaunchWeb.{AgentGuides, Paths, ToolManifest}
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

  @needs %{
    "none" => "Nothing",
    "siwa" => "Per-request SIWA proof",
    "siwa_and_pairing" => "Per-request SIWA proof and current pairing",
    "session" => "The person's sign-in",
    "wallet_signed" => "The person's sign-in and their wallet's confirmation"
  }

  @description "Bid in token auctions where everyone pays the same price, then stake to earn stablecoins or onchain stocks."

  @site_name "Autolaunch"

  # The regents-cli release every public document names: the one these guides
  # were checked against, its source commit and its published wheel.
  @regents_cli %{
    version: "1.10.24",
    commit: "fd325437e29fc6b239955e6ce946168bea2fb4ef",
    wheel_sha256: "6310687234c5b0b5b9304973232e6ef3b0d08853f84ec9e4c82304fef979dc01"
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

  @sanitize [
    tags: ~w(h1 h2 h3 p ul ol li strong em a code pre br table thead tbody tr th td),
    tag_attributes: %{"a" => ["href"]},
    generic_attributes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "noopener noreferrer"
  ]

  @doc """
  A document's committed Markdown as sanitized HTML. A table sits in a box
  that scrolls sideways on a narrow screen and can be reached from the
  keyboard to scroll it.
  """
  # The HTML is MDEx-sanitized from the committed public Markdown.
  # sobelow_skip ["XSS.Raw"]
  def html(markdown) do
    markdown
    |> MDEx.to_html!(extension: [table: true, inline_code_attributes: false], sanitize: @sanitize)
    |> String.replace(
      "<table>",
      ~s(<div class="document-table" role="region" aria-label="Table" tabindex="0"><table>)
    )
    |> String.replace("</table>", "</table></div>")
    |> Phoenix.HTML.raw()
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
  # connector's paragraph only while it is on; `{{hosted_covered_calls}}` names
  # the covered-call hosted tools only while the site offers covered calls;
  # `{{hosted_mcp}}` says what the hosted MCP address serves, naming Claude's
  # connector while it is on.
  defp markdown(name) do
    @sources[name]
    |> String.replace("{{claude_connector}}\n\n", claude_connector(Autolaunch.OAuth.enabled?()))
    |> String.replace("{{hosted_mcp}}", hosted_mcp(Autolaunch.OAuth.enabled?()))
    |> String.replace("{{hosted_covered_calls}}", hosted_covered_calls())
    |> String.replace("{{key_facts}}", @key_facts)
    |> String.replace("{{covered_calls}}\n", covered_calls())
    |> String.replace("{{exposure}}\n", exposure())
    |> String.replace("{{tools}}", tool_table())
    |> String.replace("{{origin}}", url(""))
    |> String.replace("{{regents_cli}}", @regents_cli.version)
    |> String.replace("{{regents_cli_commit}}", @regents_cli.commit)
    |> String.replace("{{regents_cli_wheel_sha256}}", @regents_cli.wheel_sha256)
    |> String.replace("{{read_only}}", read_only_now())
    |> String.replace("{{memestock_launchpad}}", memestock_launchpad())
    |> durations()
  end

  # How long each launch's auction runs and a Memestock creator's release takes,
  # in words, from the launches' fixed schedules in blocks, as the pages say it.
  defp durations(markdown) do
    revstake = RevstakeLaunchActions.schedule()
    base = LaunchActions.schedule(:base)
    robinhood = LaunchActions.schedule(:robinhood)

    Enum.reduce(
      [
        {"{{revstake_auction}}", :base, revstake.length},
        {"{{memestock_auction_base}}", :base, base.length},
        {"{{memestock_auction_robinhood}}", :robinhood, robinhood.length},
        {"{{memestock_release_base}}", :base, base.vesting},
        {"{{memestock_release_robinhood}}", :robinhood, robinhood.vesting}
      ],
      markdown,
      fn {mark, chain, blocks}, text ->
        String.replace(text, mark, LaunchChain.time_estimate(chain, blocks))
      end
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

  # The fixed pages the sitemaps list, with covered calls while the site offers them.
  defp sitemap_pages,
    do:
      if("covered_calls" in ToolManifest.features(),
        do: @sitemap_pages ++ ["/stock/covered-call"],
        else: @sitemap_pages
      ) ++ AgentGuides.paths()

  defp claude_connector(false), do: ""

  defp claude_connector(true),
    do:
      "Claude doesn't use these steps: it pairs through Autolaunch's connector, with no " <>
        "command line or key of its own. [Claude]({{origin}}/agents/claude) has the setup.\n\n"

  defp hosted_mcp(connector?) do
    "Autolaunch's hosted MCP endpoint is {{origin}}/mcp. Every call there carries a paired " <>
      "agent's signature, as for a signed request: `autolaunch_auction_counts` reads how many " <>
      "auctions are live and graduated, with the same answer as the browser tool and the API." <>
      hosted_covered_calls() <>
      " Reading without signing in is the browser tools and the API." <> connector(connector?)
  end

  # The covered-call hosted tools, named only while the site offers covered calls.
  defp hosted_covered_calls do
    if "covered_calls" in ToolManifest.features(),
      do:
        " While covered calls are open, `covered_call_book`, `covered_call_quote`, " <>
          "`covered_call_positions` and `prepare_covered_call` do there what the covered-call " <>
          "routes do, with the same answers and refusals; the steps only once launches are open.",
      else: ""
  end

  defp connector(false), do: ""

  defp connector(true),
    do:
      " It is also Claude's connector: the person adds it in Claude's settings, then signs " <>
        "in here when Claude asks and allows it. Claude's tools there (`get_identity`, " <>
        "`register_identity`, `pair_identity` and `check_in`) only keep an identity for the " <>
        "connection, pair it with the person's account and check in. " <>
        "[Claude]({{origin}}/agents/claude) has the setup."

  # The contract as the site offers it now: with every feature switched off it is
  # api-contract.openapiv3.yaml exactly; each feature that is on adds its paths
  # and components.
  defp contract do
    on = ToolManifest.features()

    [{"covered_calls", @covered_calls_contract}, {"exposure", @exposure_contract}]
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
