---
summary: "Sakana AI provider: manual Cookie header, billing page parser, 5-hour and weekly quota windows."
read_when:
  - Adding or modifying the Sakana AI provider
  - Debugging Sakana AI cookie import or quota parsing
  - Adjusting Sakana AI menu labels or reset window display
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
- Reset dates are parsed from the billing page using the device's local time zone (`TimeZone.current`).
  The fetcher detects `"MMMM d, yyyy 'at' h:mm a"` format strings.
- Plan name and price label (e.g. `Standard $20/mo`) are joined and surfaced as the `loginMethod` identity field for
  plan display in the menu.
- Token cost tracking (`supportsTokenCost: false`): not supported; cost summary is unavailable.
- Credits row (`supportsCredits: false`): not shown.
- Widget support: not currently available for Sakana AI.

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
  - `SakanaUsageFetcher.swift` — billing-page HTML fetch and quota parser
- `Sources/CodexBar/Providers/Sakana/`
  - `SakanaProviderImplementation.swift` — settings UI, availability check
  - `SakanaSettingsStore.swift` — `sakanaCookieHeader` settings binding
- `Tests/CodexBarTests/SakanaUsageFetcherTests.swift` — parser regression tests
- Dashboard: `https://console.sakana.ai/billing`
