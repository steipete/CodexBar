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
- Reset dates are parsed as **UTC**, not the device's local time zone. The billing page always server-renders
  "Resets on <date>" in UTC — the browser only corrects it to the viewer's local time client-side, after JS
  hydration, which this HTML-only fetcher never runs. (Parsing with `TimeZone.current` instead shifted every reset
  by the device's UTC offset; see [#1826](https://github.com/steipete/CodexBar/issues/1826).) The fetcher detects
  `"MMMM d, yyyy 'at' h:mm a"` format strings.
- Plan name and price label (e.g. `Standard $20/mo`) are joined and surfaced as the `loginMethod` identity field for
  plan display in the menu.
- Token cost tracking (`supportsTokenCost: false`): not supported; cost summary is unavailable. Sakana has no
  organization-level usage/cost API to query historically, only the per-request `usage` object returned by chat
  completions calls (which CodexBar never makes), so there is no local-log source to scan the way Claude/Codex are.
- Credits row (`supportsCredits: false`): not shown. The shared credits-card UI path (`MenuCardView+Costs.swift`)
  has no Sakana branch and would just render the static `creditsHint` string instead of the fetched balance, so
  `supportsCredits` stays off; the balance is surfaced explicitly instead (see below).
- Widget support: not currently available for Sakana AI.

## Pay-as-you-go credits

Sakana also sells prepaid credit for pay-as-you-go API usage (the model IDs `fugu` and `fugu-ultra`), separate from
the subscription quota windows above. `console.sakana.ai/billing` renders this data server-side under its
"Pay as you go" tab, but that tab's markup is only present in the HTML response when the request URL includes
`?tab=payAsYouGo` — the default `/billing` response (used for the subscription quota fetch above) does not include
it. CodexBar issues a **second, best-effort** GET to `https://console.sakana.ai/billing?tab=payAsYouGo` with the same
cookie header alongside the subscription request — skipped entirely (no request made) when
`context.includeOptionalUsage` is `false`, i.e. Settings → Advanced → "Show optional credits and extra usage" is
disabled.

- **Credit balance**: parsed from the `<h2>Credit balance</h2>` card's adjacent `tabular-nums` amount.
- **Recent usage total**: parsed from the `Usage` chart header's `Total: $…` text, covering whatever date range is
  currently selected on the console (defaults to the last 30 days). React renders this text with `<!-- -->`
  hydration-boundary comments splitting the label from the amount; the parser strips those before reading the value.
- **Date range label**: the raw text of the "Usage date range" picker button (e.g. `Jun 02, 2026 - Jul 01, 2026`),
  kept only as context — CodexBar does not currently interpret it as start/end dates.

This second fetch never throws and never blocks the primary result: if it fails (network error, non-200, wrong
origin, empty body, or the expected markup isn't found), the pay-as-you-go fields are simply absent from that
refresh and the subscription quota windows are returned exactly as before. An account with no pay-as-you-go credit
purchased still returns a `$0.00` balance (the card is always rendered), so absence here almost always means the
request itself failed rather than "no credit."

The optional request runs concurrently with the required subscription request and has its own five-second bound.
It is cancelled when the required request fails or the caller cancels, so it cannot add a second full request
timeout or outlive the refresh that started it.

- Menu: an `Extra usage` card shows `Balance: $X.XX` and, when available, `Usage: $X.XX` alongside the quota windows.
  The values are gated on Settings → Advanced → "Show optional credits and extra usage" at **both**
  the fetch and the render layer: turning the setting off only rebuilds the menu without an immediate refetch, so a
  previously-fetched balance would otherwise linger in the cached snapshot until the next refresh. Both the live
  menu-card model and the text descriptor hide the values whenever the setting is off, independent of cached data.
- Not shown in the menu bar text: unlike some other credits-only providers, Sakana already has real 5-hour/weekly
  rate windows, and the "secondary metric" preference that would otherwise select an alternate menu bar display is
  the legitimate way to show the *weekly* window there. Reusing it for the PAYG balance would silently replace the
  weekly percentage for anyone who picks that preference, so the balance is menu-only for now.

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
| `missingCookie` | No `Cookie:` header is configured and `SAKANA_COOKIE` is unset. |
| `loginRequired` | The request was unauthorized/forbidden, redirected, or ended on a different origin. |
| `apiError(Int)` | The billing page returned a non-`200` status not classified as a login failure. |
| `parseFailed(String)` | The billing response was empty or its quota data could not be parsed. |

## Related files

- `Sources/CodexBarCore/Providers/Sakana/`
  - `SakanaProviderDescriptor.swift` — provider metadata, fetch plan, CLI config
  - `SakanaSettingsReader.swift` — `SAKANA_COOKIE` env key, cookie normalizer
  - `SakanaUsageFetcher.swift` — billing-page HTML fetch and quota parser; also defines
    `SakanaPayAsYouGoSnapshot` and the pay-as-you-go tab fetch/parser
- `Sources/CodexBar/Providers/Sakana/`
  - `SakanaProviderImplementation.swift` — settings UI, availability check
  - `SakanaSettingsStore.swift` — `sakanaCookieHeader` settings binding
- `Sources/CodexBar/MenuCardView+Costs.swift` — live menu-card balance and usage section
- `Sources/CodexBar/MenuDescriptor.swift` — text-descriptor balance and usage rows
- `Tests/CodexBarTests/SakanaUsageFetcherTests.swift` — parser regression tests
- Dashboard: `https://console.sakana.ai/billing` (subscription tab), `https://console.sakana.ai/billing?tab=payAsYouGo`
  (pay-as-you-go tab)
