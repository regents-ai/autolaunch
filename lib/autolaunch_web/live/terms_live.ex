defmodule AutolaunchWeb.TermsLive do
  use AutolaunchWeb, :live_view

  @route_css_path Path.expand("../../../priv/static/launch-docs-live.css", __DIR__)
  @external_resource @route_css_path
  @route_css File.read!(@route_css_path)

  @sections [
    %{
      title: "1. What this covers",
      paragraphs: [
        "These Terms govern your use of autolaunch.sh and related services operated by Regents Labs, Inc. They apply to the website, the launch workflow, the auction pages, the token-holder tools, and any related pages or APIs we make available."
      ]
    },
    %{
      title: "2. Eligibility and account use",
      paragraphs: [
        "You must be old enough and legally able to use the service where you live. If you use Autolaunch for a company or other entity, you must have authority to bind that entity.",
        "You are responsible for the wallet, keys, and authentication method you connect to the site. Keep your access credentials secure and do not let anyone use them without your permission."
      ]
    },
    %{
      title: "3. Token auctions and agent tokens",
      paragraphs: [
        "Autolaunch may support agent launches, token auctions, and related actions for $REGENT and other agent tokens. A token auction can be used to discover price, distribute supply, and split onchain revenue rights for an agent business.",
        "The site may show auction data, revenue data, staking data, and contract data. Those screens are informational and operational. They are not a promise that any token will rise in value or produce revenue."
      ]
    },
    %{
      title: "4. Fees, transactions, and finality",
      paragraphs: [
        "Blockchain transactions can fail, take time, or settle differently from the estimate shown in the browser. You are responsible for network fees, wallet fees, and the accuracy of the transaction you approve.",
        "Onchain actions are generally irreversible. If the site displays a preview, that preview is only a guide. The smart contract and the network ultimately determine the result."
      ]
    },
    %{
      title: "5. Acceptable use and risk",
      paragraphs: [
        "Do not use the site for fraud, manipulation, spam, unauthorized access, or any other unlawful activity. Do not misstate the economics, rights, or status of any token or agent.",
        "Token prices, revenue, and staking rewards can move quickly and may go to zero. You accept those risks when you use the site or any token-related feature."
      ]
    },
    %{
      title: "6. Content, IP, and privacy",
      paragraphs: [
        "You keep ownership of content you submit, but you grant Regents Labs, Inc. the limited rights needed to operate the site, display your content, and provide the services you ask for.",
        "Autolaunch's name, logos, and software remain our property or the property of our licensors. Your use of the site is also governed by our Privacy Policy."
      ]
    },
    %{
      title: "7. Changes and contact",
      paragraphs: [
        "We may update these Terms when the site changes or when the law changes. The current version is the one posted on this page.",
        "If you have questions about these Terms, contact us at the support channel listed on the site."
      ]
    }
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Terms & Conditions")
     |> assign(:active_view, "legal")
     |> assign(:sections, @sections)}
  end

  def render(assigns) do
    ~H"""
    <style><%= Phoenix.HTML.raw(route_css()) %></style>
    <.shell current_human={@current_human} active_view={@active_view}>
      <div id="al-docs-page" data-docs-page="terms">
        <AutolaunchWeb.DocsFamilyComponents.header
          active="terms"
          title="Terms for autolaunch.sh"
          body="Last updated April 7, 2026. These terms cover the website, launch workflow, auction pages, token holder tools, and related services operated by Regents Labs, Inc."
          eyebrow="Terms"
        />

        <section class="al-panel al-legal-hero">
          <div>
            <p class="al-kicker">Terms and conditions</p>
            <h2>What this agreement covers</h2>
            <p class="al-subcopy">
              This page explains who can use the service, how onchain actions work, and the limits
              of what Autolaunch provides.
            </p>
          </div>
        </section>

        <section class="al-legal-grid">
          <article :for={section <- @sections} class="al-panel al-legal-card">
            <h3>{section.title}</h3>
            <p :for={paragraph <- section.paragraphs}>{paragraph}</p>
          </article>
        </section>

        <section class="al-panel al-legal-footer">
          <p>
            autolaunch.sh is a product of Regents Labs, Inc. The service is built for operator
            review, token auctions, and related agent-token flows.
          </p>
        </section>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp route_css, do: @route_css
end
