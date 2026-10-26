---
summary: "Sakana AI provider: manual Cookie header, billing page parser, 5-hour/weekly quota windows, and pay-as-you-go credit balance."
read_when:
  - Adding or modifying the Sakana AI provider
  - Debugging Sakana AI cookie import or quota parsing
  - Adjusting Sakana AI menu labels or reset window display
  - Debugging Sakana pay-as-you-go credit balance or usage-total parsing
---

# Sakana AI

[Sakana AI](https://sakana.ai) is a research lab focusing on foundation models and nature-inspired AI. CodexBar reads
the billing page to surface 5-hour and weekly quota windows for subscribers.

## Setup

1. Sign in at [console.sakana.ai](https://console.sakana.ai).
2. Open your browser's developer tools, navigate to the **Network** tab, and reload the billing page
   (`console.sakana.ai/billing`).
3. Copy the full `Cookie:` request header value from any billing-page request.
4. In CodexBar, paste the header in **Settings → Providers → Sakana AI → Cookie header**.
   The value is stored unencrypted in the [resolved config file](configuration.md#location). CodexBar sets that file's
   permissions to `0600` whenever it writes the file on macOS or Linux.

Alternatively, set the environment variable `SAKANA_COOKIE` to the raw cookie header value.

## Data source

- **Auth method**: manual `Cookie:` header; no automatic browser cookie import.
- **Target page**: `https://console.sakana.ai/billing` (HTML scrape; no JSON API).
- **Source label**: `web`.

## Usage details

- The primary row shows the **5-hour quota** as a 300-minute session window and uses the reset timestamp shown on the
  billing page when one is present.
- The secondary row shows the **weekly quota** as a seven-day window and uses its billing-page reset timestamp when
  one is present.
- `usedPercent` for each window is parsed from the billing page's adjacent `% used` text.
- Reset dates use **UTC** and the `"MMMM d, yyyy 'at' h:mm a"` format. Server-rendered "Resets on <date>" text is UTC; the browser's local-time conversion requires JavaScript, which this HTML fetcher does not run.
- Plan name and price label (e.g. `Standard $20/mo`) are joined and surfaced as the `loginMethod` identity field for
  plan display in the menu.
- Token cost tracking (`supportsTokenCost: false`): unavailable. Sakana has no historical organization usage/cost API or local-log source, only per-request `usage` from chat completions, which CodexBar never calls.
- Shared credits row (`supportsCredits: false`): unavailable; that path renders only `creditsHint` for Sakana. PAYG balance appears in **Extra usage** instead.
- Widget support: not currently available for Sakana AI.

## Pay-as-you-go credits

Prepaid PAYG credit for `fugu` and `fugu-ultra` is separate from subscription quotas. Enable **Settings → Advanced → Show optional credits and extra usage** to fetch `GET https://console.sakana.ai/billing?tab=payAsYouGo` alongside the subscription request, using the same cookie. The default `/billing` HTML omits this tab. Turning the setting off (`context.includeOptionalUsage: false`) skips the request and immediately hides cached PAYG values in both menu cards and text descriptors, without a refetch.

- **Credit balance**: parsed from the `<h2>Credit balance</h2>` card's adjacent `tabular-nums` amount.
- **Recent usage total**: parsed from the `Usage` chart header's `Total: $…` text, covering whatever date range is
  currently selected on the console (defaults to the last 30 days). React renders this text with `<!-- -->`
  hydration-boundary comments splitting the label from the amount; the parser strips those before reading the value.
- **Date range label**: the raw text of the "Usage date range" picker button (e.g. `Jun 02, 2026 - Jul 01, 2026`),
  kept only as context — CodexBar does not currently interpret it as start/end dates.

PAYG failures (network, non-200, wrong origin, empty body, or missing markup) omit those fields without failing subscription usage. Accounts with no purchased credit still return `$0.00`; absence generally indicates a failed request.

The `sakana.js` plugin uses `ctx.http.getWithOptional` on QuickJS and JavaScriptCore, with host-owned concurrency and cancellation on macOS/Linux. PAYG has a five-second request limit and no retry. Collection has a shared 200 ms budget from primary request start: slow primaries take only completed PAYG data; fast primaries can wait the remainder. Unfinished PAYG work is cancelled on collection, primary failure, or caller cancellation. Primary timeouts are clamped to 1–90 seconds within a sufficient overall fetch budget.

The **Extra usage** card shows `Balance: $X.XX` and optional `Usage: $X.XX` alongside quotas. PAYG is menu-only; menu-bar text uses quota windows, with **secondary metric** selecting weekly usage.

## CLI usage

```
codexbar usage --provider sakana
codexbar usage --provider sakana-ai   # alias
```

Set the cookie via the environment variable or Settings UI:

- **Environment variable**: `SAKANA_COOKIE=<cookie-header-value> codexbar usage --provider sakana`
- **Settings UI**: Settings → Providers → Sakana AI → Cookie header

There is no `codexbar config set` command for `cookieHeader`; use one of the paths above.

## Errors

| Error | Meaning |
|-------|---------|
| No available fetch strategy | No `Cookie:` header is configured and `SAKANA_COOKIE` is unset. |
| `authentication-expired` | The request was unauthorized/forbidden, redirected, or ended on a different origin. |
| `api-failure` | The billing page returned a non-`200` status not classified as a login failure. |
| `parse-failure` | The billing response was empty or its quota data could not be parsed. |

## Related files

- `Sources/CodexBarCore/Providers/Sakana/`
  - `SakanaProviderDescriptor.swift` — provider metadata, fetch plan, CLI config
  - `SakanaSettingsReader.swift` — `SAKANA_COOKIE` env key, cookie normalizer
- `Sources/CodexBarCore/Resources/Plugins/sakana.js` — billing and PAYG parsing into generic usage/details
- `Sources/CodexBarCore/Plugins/ProviderPluginHTTPResponse.swift` — bounded optional GET collection
- `Sources/CodexBar/Providers/Shared/PluginCookieProviderImplementation.swift` — shared cookie field and availability
- `Sources/CodexBar/Menu/MenuCardView+Costs.swift` — live menu-card balance and usage section
- `Sources/CodexBar/Menu/MenuDescriptor.swift` — text-descriptor balance and usage rows
- Dashboard: `https://console.sakana.ai/billing` (subscription tab), `https://console.sakana.ai/billing?tab=payAsYouGo`
  (pay-as-you-go tab)
