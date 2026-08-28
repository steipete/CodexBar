---
summary: "Crof provider data source: API key + usage_api credit balance and optional request quota."
read_when:
  - Adding or tweaking Crof usage parsing
  - Updating Crof API key handling
---

# Crof provider

Crof is API-only. CodexBar reads `GET https://crof.ai/usage_api/` with a Bearer token
and displays the returned dollar credit balance plus request quota fields when available.

## Data sources

1. **API key** supplied via `CROF_API_KEY`, `CROFAI_API_KEY`, or Settings →
   Providers → Crof. Settings values are stored in `~/.codexbar/config.json`.
2. **Usage endpoint**
   - `GET https://crof.ai/usage_api/`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response fields used: `credits`, plus optional `requests_plan` / `usable_requests`
   - Ignored: per-model `usage` token totals

## Usage details

- When both request-quota fields are present, the primary row shows request quota and
  the exact usable request count; the secondary row shows the dollar balance.
- When the request-quota fields are null or absent, the primary row falls back to the
  dollar balance so PAYG-only accounts still render successfully.
- Dollar balances are floored to cents so tiny microcent-level burns never overstate
  the remaining balance.
- With no credit cap in the API, the bar only indicates present vs. exhausted credits.
- Request reset timing is inferred as the next `America/Chicago` midnight only for
  accounts that return request-quota fields.
- The provider icon is SVG and CodexBar renders it as a template image so it
  matches the other monochrome provider icons.
- Dashboard: `https://crof.ai/dashboard`.

## Related files

- `Sources/CodexBarCore/Resources/Plugins/crof.js` (macOS implementation)
- `Sources/CodexBarCore/Providers/Crof/` (descriptor/settings plus Linux compatibility fetcher)
- `Sources/CodexBar/Providers/Crof/`
- `Tests/CodexBarTests/CrofUsageFetcherTests.swift` (JavaScript goldens)
