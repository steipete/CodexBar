---
summary: "Mistral provider: browser cookie setup, billing usage, credit balance, and Vibe monthly-plan usage."
read_when:
  - Configuring Mistral usage
  - Debugging Mistral billing or Vibe usage requests
  - Adjusting Mistral cost, credit, or monthly-plan display
---

# Mistral Provider

CodexBar reads Mistral billing usage with the Mistral web session from `admin.mistral.ai`. It can also fetch credit
balance and, when the required CSRF/session cookies are present, best-effort Mistral Vibe monthly-plan usage.

## Setup

1. Open **Settings -> Providers**.
2. Enable **Mistral**.
3. Sign in to [Mistral Admin](https://admin.mistral.ai/organization/usage) in Chrome, Firefox, or Safari.
4. Leave Cookie source on **Automatic**, or switch to **Manual** and paste a `Cookie:` header from a request to
   `admin.mistral.ai`.

Manual cookies must include an `ory_session_*` cookie. A `csrftoken` cookie enables authenticated billing and Vibe
requests that require the `X-CSRFTOKEN` header.

Automatic import tries Chrome, Firefox (including Developer Edition), then Safari. Safari requires Full Disk Access.
Other Chromium browsers remain available through Manual mode. Automatic import reads only unexpired cookies from
the documented Mistral domains.

## Data Sources

CodexBar requests the current UTC month from Mistral Admin:

- `GET https://admin.mistral.ai/api/billing/v2/usage?month=<month>&year=<year>`
- `GET https://admin.mistral.ai/api/billing/credits` (best-effort credit balance)

When a CSRF token is available, CodexBar also makes a bounded best-effort request for Mistral Vibe plan usage:

- `GET https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?...`

For the console request, CodexBar forwards only the `csrftoken` and `ory_session_*` cookies. Other
`admin.mistral.ai` cookies stay origin-bound.

## Display

- API spend is computed locally from the billing usage response's token counts and pricing table.
- Daily usage buckets feed the inline usage dashboard.
- The provider card can show credit balance when the credits endpoint returns it.
- The optional **Monthly Plan** window shows Vibe usage percentage and reset time when the console endpoint is
  available.
- Token-cost history is supported through the billing web session; no local log scan is used.

## CLI Usage

```bash
codexbar usage --provider mistral --verbose
```

## Troubleshooting

### "No Mistral session cookies found"

Sign in to [Mistral Admin](https://admin.mistral.ai/organization/usage) in Chrome, Firefox, or Safari, then refresh.

### "Mistral cookie header is invalid"

In manual mode, paste a full `Cookie:` header from an `admin.mistral.ai` request. The header must include an
`ory_session_*` cookie.

### Credits or Vibe plan usage are missing

The billing usage request is required. Credits and Vibe usage are best-effort; if either optional endpoint fails or
does not expose data for the account, CodexBar keeps the main Mistral usage result.

## Related Files

- `Sources/CodexBarCore/Providers/Mistral/MistralProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralModels.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralCookieImporter.swift`
- `Sources/CodexBar/Providers/Mistral/MistralProviderImplementation.swift`
