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

- `rollingFiveHourLimit` -> Five-hour quota
- `planWeeklyLimit` -> Weekly credits (percent remaining, next regeneration time, and next regeneration percent).
  Those percentages are already on a 0-100 scale, including values at or below 1.
- `weeklyTokenLimit` -> Weekly tokens, used when `planWeeklyLimit` is absent
- `search.hourly` -> Search hourly

`subscription` on current plans is a legacy request counter. CodexBar ignores it
when any known lane above is present. A response that only contains
`subscription` still maps that counter into the primary quota slot.

If those keys are absent, CodexBar falls back to generic quota payloads such as
`quotas`, `quota`, `limits`, `usage`, `entries`, or `subscription`.

## Display

- The menu card shows the five-hour, weekly, and search-hourly lanes when present. Weekly credits from
  `planWeeklyLimit` keep the returned percent (for example 99.60% left) and read
  `Regenerates 2% in 3h 11m`. The compact menu bar metric uses the five-hour or weekly lane.
- Usage is normalized from percent fields when present, or computed from used/remaining/limit values.
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
