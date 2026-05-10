---
summary: "Crof provider data source: API key + usage_api request quota."
read_when:
  - Adding or tweaking Crof usage parsing
  - Updating Crof API key handling
  - Documenting Crof reset behavior
---

# Crof provider

Crof is API-only. CodexBar reads `GET https://crof.ai/usage_api/` with a
Bearer token and displays the returned request quota and dollar credit balance.

## Data sources

1. **API key** supplied via `CROF_API_KEY`, `CROFAI_API_KEY`, or Settings →
   Providers → Crof. Settings values are stored in `~/.codexbar/config.json`.
2. **Usage endpoint**
   - `GET https://crof.ai/usage_api/`
   - Request headers: `Authorization: Bearer <api key>`, `Accept: application/json`
   - Response fields: `credits`, `requests_plan`, `usable_requests`

## Usage details

- The primary row shows request quota with the exact usable request count on the right.
  The visible remaining percent is floored so partially used quotas like `998/1000`
  do not round up to `100% left`.
- Crof support said quota reset is around midnight Central time; CodexBar models this
  as the next `America/Chicago` midnight so daylight saving time maps to GMT-5 when
  appropriate.
- The secondary row shows the current Crof dollar balance, floored to cents so tiny
  microcent-level burns never overstate the remaining balance.
- Reset timing is inferred until Crof exposes reset metadata in the usage API.
- The provider icon is SVG and CodexBar renders it as a template image so it
  matches the other monochrome provider icons.
- Dashboard: `https://crof.ai/dashboard`.

## Related files

- `Sources/CodexBarCore/Providers/Crof/`
- `Sources/CodexBar/Providers/Crof/`
- `Tests/CodexBarTests/CrofUsageFetcherTests.swift`
