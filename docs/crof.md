---
summary: "Crof provider data source: API key + usage_api PAYG credit balance."
read_when:
  - Adding or tweaking Crof usage parsing
  - Updating Crof API key handling
---

# Crof provider

Crof is API-only and PAYG-only. CodexBar reads `GET https://crof.ai/usage_api/` with a
Bearer token and displays the returned dollar credit balance.

## Data sources

1. **API key** supplied via `CROF_API_KEY`, `CROFAI_API_KEY`, or Settings →
   Providers → Crof. Settings values are stored in `~/.codexbar/config.json`.
2. **Usage endpoint**
   - `GET https://crof.ai/usage_api/`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response fields used: `credits`
   - Ignored: null `requests_plan` / `usable_requests` (subscription removed), and
     per-model `usage` token totals

## Usage details

- Crof no longer exposes a request quota. CodexBar tracks only the PAYG credit balance.
- The primary row shows the current Crof dollar balance, floored to cents so tiny
  microcent-level burns never overstate the remaining balance.
- With no credit cap in the API, the bar only indicates present vs. exhausted credits.
- The provider icon is SVG and CodexBar renders it as a template image so it
  matches the other monochrome provider icons.
- Dashboard: `https://crof.ai/dashboard`.

## Related files

- `Sources/CodexBarCore/Providers/Crof/`
- `Sources/CodexBar/Providers/Crof/`
- `Tests/CodexBarTests/CrofUsageFetcherTests.swift`
