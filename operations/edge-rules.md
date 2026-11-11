# Edge rules

Cloudflare sits in front of autolaunch.sh. Two rules on the autolaunch.sh zone keep the stock
products away from the regions they are not offered in. Sean owns both; they live in the
Cloudflare dashboard, not in this repository.

## Redirect: the stock pages to /unavailable

A browser opening a stock page from a region it is not offered in lands on `/unavailable`, a
site page with the top bar and rail, instead of Cloudflare's own block page. Single Redirects
(`http_request_dynamic_redirect`) run before WAF custom rules in Cloudflare's phase list, so this
rule answers the two pages and the block rule below still answers everything else.

Rules › Overview › Create rule › Redirect Rule:

- Name: `Stock pages: not offered here`
- Custom filter expression, Edit expression:

  ```
  (http.request.uri.path in {"/stock/covered-call" "/stock/isolated-afters"} and ip.src.country in {"US"})
  ```

  The country list is the block rule's list.
- Then: Static, URL `https://autolaunch.sh/unavailable`, status code 302, Preserve query string off.

Both pages sit in their own live session (`live_session :stock` in the router), so arriving from any
other page is a full page load the rule sees. A new stock page joins that session and this rule's
path list.

## Block: everything under /stock/ and the stock API

WAF custom rule, Block, on `/stock/*` and the stock HTTP API routes for the same countries. It
stays as it is: share pictures, videos, series terms and API reads are answered with a refusal,
not a page.
