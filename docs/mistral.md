---
summary: "Mistral provider: browser cookie setup, billing usage, included API/Vibe allowances, and credits."
read_when:
  - Configuring Mistral usage
  - Debugging Mistral billing or Vibe usage requests
  - Adjusting Mistral cost, credit, or monthly-plan display
---

# Mistral Provider

CodexBar can read Mistral's Included API and Vibe Code allowances with an API key. For monthly spend, token history,
and credits, use a Mistral Admin browser session instead.

## Setup

1. Open **Settings -> Providers**.
2. Enable **Mistral**.
3. Choose **Usage source**. **Auto** tries the API key first and falls back to browser cookies when cookie access is
   enabled; **API key** reads allowances only; **Browser cookies** reads spend, token history, credits, and allowances.

For allowances only, enter an **API key**. In Auto mode CodexBar tries the key first. If the key request fails,
it falls back to the browser if cookies are enabled. Set **Cookie source → Off** to disable this fallback.

For spend and token history, either leave the API key field empty or set **Usage source → Browser cookies**, then sign
in to [Mistral Admin](https://admin.mistral.ai/organization/usage) in a supported browser. Leave Cookie source on
**Automatic**, or switch to **Manual** and paste a `Cookie:` header from a request to `admin.mistral.ai`.

Manual cookies must include an `ory_session_*` cookie. A `csrftoken` cookie enables fallback Vibe requests that
require the `X-CSRFTOKEN` header.

On Linux, use an API key (`MISTRAL_API_KEY` in the environment or the Mistral provider's `apiKey` config field),
or set `cookieSource` to `manual` and `cookieHeader` to the pasted header in `~/.config/codexbar/config.json`.
A selected saved cookie account does not inherit the provider-level API key.

Automatic import follows the shared supported-browser order. Safari requires Full Disk Access.
The shared access gate bounds Keychain prompts. Automatic import reads only unexpired cookies from
the documented Mistral domains.

## Data Sources

API-key mode reads `GET https://api.mistral.ai/v1/billing/budget`. This endpoint is not part of the documented
Mistral Admin API. Key access can vary, and a missing allowance is not reported as zero usage.

Browser mode requests the current UTC month, subscription allowances, and credits from Mistral Admin:

- `GET https://admin.mistral.ai/api/billing/v2/usage?month=<month>&year=<year>`
- `GET https://admin.mistral.ai/subscription` (best-effort included API and Vibe allowances)
- `GET https://admin.mistral.ai/api/billing/credits` (best-effort credit balance)

If the subscription page has no Vibe allowance and a CSRF token is available, CodexBar makes a bounded best-effort
fallback request:

- `GET https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?...`

For the console request, CodexBar forwards only the `csrftoken` and `ory_session_*` cookies. Other
`admin.mistral.ai` cookies stay origin-bound.

## Display

- **Included API** shows the subscription allowance's used percentage, used / total / remaining amount, and reset time.
- The optional **Monthly Plan** window shows the separate Vibe Code allowance with the same details.
- API spend is computed from billed units (`value_paid`, falling back to `value`) and the pricing table. Each unit takes
  the price with the same event type, metric, group, API zone, and service tier; the table lists one metric under
  several of these, and audio-second and priority prices are far higher than standard token prices. Token totals
  and daily buckets use consumed units (`value`, falling back to `value_paid`), so plan-covered usage still counts.
  Legacy tables that omit both API zone and service tier use the unqualified price for the same event type, metric, and group.
- Token totals include API completions, Le Chat, and Vibe Code completions from the billing usage response.
- Daily usage buckets feed the inline usage dashboard.
- The provider card can show credit balance when the credits endpoint returns it.
- Allowance amounts derive from Mistral's reported percentage and allowance size, independently of billed API spend. Zero or malformed allowances are omitted without discarding a valid sibling allowance.
- The Automatic menu bar selection retains API spend in browser mode. In API-key mode it uses Included API, or
  Monthly Plan if that's the only allowance reported. Included API and Monthly Plan select their respective quotas.
- Token-cost history is supported through the billing web session; no local log scan is used.
- Unrepresentable billing token totals fail parsing instead of crashing. Display-only model rankings omit an
  overflowing total while retaining valid cost data.
- Final input, cached, and output totals allow signed adjustments in any lane while rejecting totals outside the
  supported integer range.

## Widgets

Usage widgets follow the **Menu bar metric** picker in Mistral's provider settings. The picker appears in every menu bar
style, so Critters and Meter bars users can still pick the widget allowance. Choosing a percentage metric pins
Mistral’s layout against later global layout edits. Without a percentage, the picker changes only the stored metric
and keeps following the global layout:

- **Automatic** and **Included API** show only the API allowance, preserving the existing default.
- **Monthly Plan** shows only the Vibe allowance, falling back to Included API when the plan is missing or unknown.

Automatic still shows API spend in the menu bar. Changing the metric updates widget rows from the existing snapshot,
without another request. After a failed refresh, widgets reselect from the last published usage snapshot and keep its
original measurement time, including across repeated metric changes. This in-memory source is cleared when provider
or account ownership is invalidated. Burn Down eligibility still requires a known window duration and reset.

## CLI Usage

```bash
codexbar usage --provider mistral --verbose
```

Use `--source api` to require an API key, or `--source web` to require cookies even when a key is configured.
Use `--log-level debug` to see which optional browser request failed; logs omit response bodies and credentials.

Text output includes both Included API and the optional Monthly Plan, each with its percentage, reset date when
available, and used / total / remaining amounts. Amounts are shown as detail, never as a reset time. This uses the
existing snapshot; no additional requests are made. JSON output is unchanged: the Monthly Plan remains in
`extraRateWindows` with the ID `mistral-monthly-plan`.

## Troubleshooting

### "No Mistral session cookies found"

Sign in to [Mistral Admin](https://admin.mistral.ai/organization/usage) in a supported browser, then refresh.

### "Mistral cookie header is invalid"

In manual mode, paste a full `Cookie:` header from an `admin.mistral.ai` request. The header must include an
`ory_session_*` cookie.

### "Mistral session expired or invalid"

Mistral answers an expired `ory_session_*` cookie with a redirect to `auth.mistral.ai/self-service/login`. CodexBar
treats that redirect like HTTP 401/403: in Automatic mode it clears the cached cookie and tries the browser sessions
again. If every browser session is expired too, sign in to Mistral Admin again.

### Included allowance, credits, or Vibe plan usage are missing

If billing history returns HTTP 404, 410, or a server error, or its report is unreadable, CodexBar can still show
allowances or a credit balance returned by the same browser session. Spend and token history are **unavailable**, not
zero. If neither allowances nor credits can be read, CodexBar reports the original billing error. A sign-in failure
still triggers normal session recovery; a rate limit does not trigger extra requests.

When billing history succeeds, a missing allowance or balance does not hide that history.

## Related Files

- `Sources/CodexBarCore/Providers/Mistral/MistralProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralSubscriptionBudgetParser.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralModels.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralCookieImporter.swift`
- `Sources/CodexBar/Providers/Mistral/MistralProviderImplementation.swift`
