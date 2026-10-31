---
summary: "Synthetic provider data sources: API key quota endpoint and usage lanes."
read_when:
  - Debugging Synthetic API key usage
  - Updating Synthetic quota parsing
  - Explaining Synthetic setup and environment variables
---

# Synthetic provider

Synthetic is API-key only. CodexBar reads the quota endpoint and maps the
known Synthetic quota lanes into the shared provider card.

## Authentication

Create an API key using [Synthetic's API guide](https://dev.synthetic.new/docs/api/getting-started), then add it in
Settings -> Providers -> Synthetic, or set:

```bash
export SYNTHETIC_API_KEY="..."
```

You can also store the key through the CLI:

```bash
printf '%s' "$SYNTHETIC_API_KEY" | codexbar config set-api-key --provider synthetic --stdin
```

## Data source

CodexBar sends a read-only request to [Synthetic's quota API](https://dev.synthetic.new/docs/synthetic/quotas):

```http
GET https://api.synthetic.new/v2/quotas
Authorization: Bearer <api key>
Accept: application/json
```

The parser first looks for Synthetic's known quota slots, either at the root
of the response or under `data`:

- `planWeeklyLimit` (or the older `weeklyTokenLimit`) -> Weekly quota
- `search.hourly` -> Search hourly

Current [Synthetic plans use weekly credit limits](https://synthetic.new/rate-limits), with no additional
five-hour limit. When `planWeeklyLimit` is present, CodexBar ignores the retired `subscription` counter
even if the API still returns it. Older responses can still supply a five-hour quota through
`rollingFiveHourLimit` or `subscription`.

If those keys are absent, CodexBar falls back to generic quota payloads such as
`quotas`, `quota`, `limits`, `usage`, `entries`, or `subscription`.

## Display

- The menu card shows weekly credit usage and search-hourly usage for current plans. The compact menu bar metric
  can use the weekly lane; automatic selection may choose search when it is more constrained.
  Older responses can also show a five-hour lane.
- Usage is normalized from percent fields when present, or computed from used/remaining/limit values.
- `planWeeklyLimit.percentRemaining` is read as percentage points, including values below 1%.
  Its `nextRegenAt` and `nextRegenPercent` fields supply the weekly regeneration time and amount,
  without requiring credit amounts.
- Reset timestamps are shown when Synthetic returns one. When no timestamp is available, CodexBar uses the returned
  or inferred window duration when present.
- Plan name, when returned, is displayed as provider identity context.
- Synthetic does not currently provide CodexBar cost history.
- External status page: [status.synthetic.new](https://status.synthetic.new) (not linked or auto-polled by CodexBar).

## CLI usage

```bash
codexbar usage --provider synthetic
codexbar usage --provider synthetic.new
```

## Key files

- `Sources/CodexBarCore/Providers/Synthetic/SyntheticProviderDescriptor.swift` (descriptor and script fetch strategy)
- `Sources/CodexBarCore/Resources/Plugins/synthetic.js` (HTTP client and parser)
- `Sources/CodexBarCore/Providers/Synthetic/SyntheticSettingsReader.swift` (environment variable parsing)
- `Sources/CodexBar/Providers/Shared/PluginAPIKeyProviderImplementation.swift` (spec-built settings and availability)
