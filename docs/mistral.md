---
summary: "Mistral provider: browser cookie setup, billing usage, included API/Vibe allowances, and credits."
read_when:
  - Configuring Mistral usage
  - Debugging Mistral billing or Vibe usage requests
  - Adjusting Mistral cost, credit, or monthly-plan display
---

# Mistral Provider

CodexBar reads Mistral billing usage, subscription allowances, credits, and account identity with the Mistral web
session from `admin.mistral.ai`. Vibe Code (CLI, ACP, editor extensions) consumption is included in token totals and
daily buckets; it consumes the Vibe plan allowance rather than pay-as-you-go spend.

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

CodexBar requests the current UTC month, subscription allowances, credits, and identity from Mistral Admin:

- `GET https://admin.mistral.ai/api/billing/v2/usage?month=<month>&year=<year>` (required)
- `GET https://admin.mistral.ai/api/billing/v2/budget` (best-effort included API and Vibe Code allowances)
- `GET https://admin.mistral.ai/api/billing/credits` (best-effort credit balance)
- `GET https://admin.mistral.ai/api/users/me` (best-effort account email, organization, and plan)

When the budget endpoint is unavailable, CodexBar falls back to the allowances embedded in
`GET https://admin.mistral.ai/subscription`. If neither exposes a Vibe allowance and a CSRF token is available,
CodexBar makes a bounded best-effort fallback request:

- `GET https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?...`

For the console request, CodexBar forwards only the `csrftoken` and `ory_session_*` cookies. Other
`admin.mistral.ai` cookies stay origin-bound.

The billing usage response reports each entry twice: `value` is what was consumed (tokens, pages, seconds) and
`value_paid` is the share billed pay-as-you-go. Usage covered by the included API allowance or the Vibe plan has
`value_paid == 0`. Token totals and daily buckets use `value`; API spend uses `value_paid` times the pricing table.
Categories read: `completion`, `chat`, `vibe_code.completion` (token-metered) plus `ocr`, `connectors`, `audio`,
`audio_characters`, `libraries_api`, `fine_tuning`, and their `vibe_code` siblings (cost only).

## Display

- **Included API** shows the subscription allowance's used percentage, used / total / remaining amount, and reset time.
- The optional **Monthly Plan** window shows the separate Vibe Code allowance with the same details. It is listed with
  the other rate windows in the menu and in `codexbar usage --provider mistral`, and the menu bar layout editor offers
  it as a "Monthly Plan %" token (used or left, following the usage bar setting).
- API spend is the pay-as-you-go amount computed locally from `value_paid` and the pricing table; it remains separate
  from the included allowance and the Vibe plan.
- Daily usage buckets (API and Vibe Code tokens, billed cost) feed the inline usage dashboard.
- The provider card can show credit balance when the credits endpoint returns it.
- **Account** and **Plan** come from `/api/users/me`, using the subscription page's names: `INDIVIDUAL` is shown as
  "Pro", `TEAM` as "Team", `EDU` as "Education", no chat plan as "Free" (plus "Vibe Pro" when set). A
  `PAY_AS_YOU_GO` API plan and an `ENTERPRISE` code plan are appended when present.
- Allowance amounts derive from Mistral's reported percentage and allowance size, independently of billed API spend. Zero or malformed allowances are omitted without discarding a valid sibling allowance.
- The Automatic menu bar selection shows the most constrained allowance (Included API or Monthly Plan) and falls
  back to API spend for pay-as-you-go accounts without allowances; Included API and Monthly Plan select their
  respective quota percentages.
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

### Included allowance, credits, plan, or Vibe plan usage are missing

The billing usage request is required. Subscription allowances, credits, account identity, and Vibe usage are
best-effort; if an optional source fails or does not expose data for the account, CodexBar keeps the main Mistral
usage result.

## Related Files

- `Sources/CodexBarCore/Providers/Mistral/MistralProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralSubscriptionBudgetParser.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralModels.swift`
- `Sources/CodexBarCore/Providers/Mistral/MistralCookieImporter.swift`
- `Sources/CodexBar/Providers/Mistral/MistralProviderImplementation.swift`
