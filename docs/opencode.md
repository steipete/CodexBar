---
summary: "OpenCode provider notes: browser cookies, local SQLite usage, and parsing."
read_when:
  - Adding or modifying the OpenCode provider
  - Debugging OpenCode usage parsing or cookie import
---

# OpenCode provider

## Data sources
- Browser cookies from `opencode.ai`.
- OpenCode Go usage API at `GET https://opencode.ai/zen/go/v1/usage`, authenticated by `OPENCODE_API_KEY` or
  `providers[].apiKey`.
- OpenCode Go local history from `~/.local/share/opencode/opencode.db` on macOS and Linux.
- `POST https://opencode.ai/_server` with server function IDs:
  - `workspaces` (`def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f`)
  - `subscription.get` (`7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4`)

## Usage mapping
- The Go usage API reports `usage.rolling/weekly/monthly.percent` in percentage units (0...100): `1` means 1%, and
  `0.5` means 0.5%. Generic dashboard JSON still accepts fractional usage values (0...1).
- Primary window: rolling 5-hour usage (`rollingUsage.usagePercent`, `rollingUsage.resetInSec`).
- Secondary window: optional weekly usage (`weeklyUsage.usagePercent`, `weeklyUsage.resetInSec`).
- Resets computed as `now + resetInSec`.

## Notes
- Responses are `text/javascript` with serialized objects; parse via regex.
- Missing workspace ID or rolling usage fields should raise parse errors; omitted weekly usage stays absent.
- OpenCode web Auto imports Chrome first, then Dia when their cookie stores exist; Keychain preflight stays scoped
  to each candidate browser. Other browsers stay on Manual Cookie import until CodexBar has an explicit browser
  selector.
- Set `CODEXBAR_OPENCODE_WORKSPACE_ID` to skip workspace lookup and force a specific workspace.
- Workspace override accepts a raw `wrk_…` ID or a full `https://opencode.ai/workspace/...` URL.
- Cached cookies: Keychain cache `com.steipete.codexbar.cache` (account `cookie.opencode`, source + timestamp). Browser
  import only runs when the cached cookie fails.
- OpenCode Go unscoped Auto mode tries daily cost history derived from local `opencode-go` assistant costs first,
  overlays authoritative API windows when an API key is configured, then falls back through the API and legacy web
  sources when local history is unavailable. Auto stays web-first when a token account, manual cookie, or workspace
  override scopes the request, because local history is device-wide.
- The local monthly window is an estimate anchored at the earliest local row and can drift from the real billing
  cycle. The local strategy prefers API-reported rolling/weekly/monthly percentages and reset timestamps. When no API
  key is configured, a cached or manual session cookie can still overlay the legacy web values (plus Zen balance).
  Both paths keep local daily cost history and never trigger a fresh browser import. When no authoritative overlay is
  available, the menu and text CLI label the quota as estimated, and JSON includes `dataConfidence: "estimated"`.
- OpenCode Go cost history chart: `opencode.ai` has no daily-granularity endpoint, so per-day cost/request buckets
  come from local `opencode-go` assistant costs in `opencode.db`, keyed by device-local calendar day. Successful web
  usage remains workspace-scoped and is never blended with device-wide local costs, so it does not show cost history.
  Explicit Web mode never reads the local database either.
- Each day's bucket also carries a per-model cost breakdown, read from each local assistant message's `modelID`
  (the real model behind the constant `opencode-go` Zen proxy `providerID`). This lets the shared Cost history
  chart show a per-model breakdown for OpenCode Go the same way it already does for Claude (see the "Cost usage"
  section in [docs/claude.md](claude.md)). Rows with no `modelID` are grouped under an "unknown" bucket instead of
  being dropped.
