---
summary: "OpenCode Go provider entry point: subscription usage, source selection, and local SQLite cost history."
read_when:
  - Configuring OpenCode Go separately from OpenCode
  - Finding OpenCode Go usage and local-history documentation
---

# OpenCode Go

OpenCode Go is registered separately from OpenCode as `opencodego`. It supports `auto`, `api`, and `web` sources,
with five-hour, weekly, and monthly quota windows when reported by the selected source. Local cost history reads
OpenCode Go assistant records from `~/.local/share/opencode/opencode.db`.

Without an API key or a usable cached/manual session, Auto can return `source: "local"` and
`usage.dataConfidence: "estimated"`. Its $12/$30/$60 denominators apply to five-hour, weekly, and monthly
local cost windows; they are fixed estimates, **not detected subscription tiers or Console quotas**. Local history
covers only this device, and its inferred monthly boundary can differ from the billing cycle. Even a low local
percentage cannot establish that the account has headroom. Consumers deciding account availability must check
`dataConfidence` or request `--source api` / `--source web` with valid authentication.

The menu bar prefixes estimated percentages with `~`; the expanded menu and text CLI label them as estimated.
JSON retains numeric percentages and the explicit confidence field. Available API or cached/manual session
responses already override local windows with authoritative server meters. An unscoped local read does not import
new browser cookies; use Web mode to discover a browser session. No local estimate is used for pace forecasts.
The local database scan is still performed on each fetch; these markers do not provide caching or improve scan time.

The shared [OpenCode guide](opencode.md) documents authentication, scoped source selection, usage mapping, and the
boundary between device-local estimates and account quota. Keep those details there so the two guides do not drift.

```bash
codexbar usage --provider opencodego --format json --pretty
```
