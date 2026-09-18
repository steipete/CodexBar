---
summary: "Mistral provider: browser cookie setup, billing usage, included API/Vibe allowances, and credits."
read_when:
  - Configuring Mistral usage
  - Debugging Mistral billing or Vibe usage requests
  - Adjusting Mistral cost, credit, or monthly-plan display
---

# Mistral Provider

CodexBar reads Mistral billing usage and subscription allowances with the Mistral web session from
`admin.mistral.ai`. It also fetches credit balance and falls back to the console Vibe endpoint when the subscription
page does not expose a Vibe allowance.

## Setup

1. Open **Settings -> Providers**.
2. Enable **Mistral**.
3. Sign in to [Mistral Admin](https://admin.mistral.ai/organization/usage) in Chrome, Firefox, or Safari.
4. Leave Cookie source on **Automatic**, or switch to **Manual** and paste a `Cookie:` header from a request to
   `admin.mistral.ai`.

Manual cookies must include an `ory_session_*` cookie. A `csrftoken` cookie enables fallback Vibe requests that
require the `X-CSRFTOKEN` header.

Automatic import tries Chrome, Firefox (including Developer Edition), then Safari. Safari requires Full Disk Access.
Other Chromium browsers remain available through Manual mode. Automatic import reads only unexpired cookies from
the documented Mistral domains.

## Data Sources

CodexBar requests the current UTC month, subscription allowances, and credits from Mistral Admin:

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
- API spend is computed locally from the billing usage response's token counts and pricing table; it remains separate
  from the included allowance and any pay-as-you-go spend.
- Daily usage buckets feed the inline usage dashboard.
- The provider card can show credit balance when the credits endpoint returns it.
- Allowance amounts derive from Mistral's reported percentage and allowance size, independently of billed API spend. Zero or malformed allowances are omitted without discarding a valid sibling allowance.
- The Automatic menu bar selection retains API spend; Included API and Monthly Plan select their respective quota percentages.
- Token-cost history is supported through the billing web session; no local log scan is used.
- Unrepresentable billing token totals fail parsing instead of crashing. Display-only model rankings omit an
  overflowing total while retaining valid cost data.
- Final input, cached, and output totals allow signed adjustments in any lane while rejecting totals outside the
  supported integer range.

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

### Included allowance, credits, or Vibe plan usage are missing

The billing usage request is required. Subscription allowances, credits, and Vibe usage are best-effort; if an
optional source fails or does not expose data for the account, CodexBar keeps the main Mistral usage result.

## Related Files

- `Sources/CodexBarCore/Providers/Mistral/MistralProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralSubscriptionBudgetParser.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralModels.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralCookieImporter.swift`
- `Sources/CodexBar/Providers/Mistral/MistralProviderImplementation.swift`
