---
summary: "OpenCode provider notes: browser cookie import, _server endpoints, and usage parsing."
read_when:
  - Adding or modifying the OpenCode provider
  - Debugging OpenCode usage parsing or cookie import
---

# OpenCode provider

## Data sources
- Browser cookies from `opencode.ai`.
- `POST https://opencode.ai/_server` with server function IDs:
  - `workspaces` (`def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f`)
  - `subscription.get` (`7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4`)

## Usage mapping
- Primary window: rolling 5-hour usage (`rollingUsage.usagePercent`, `rollingUsage.resetInSec`).
- Secondary window: weekly usage (`weeklyUsage.usagePercent`, `weeklyUsage.resetInSec`).
- Resets computed as `now + resetInSec`.

## Notes
- Responses are `text/javascript` with serialized objects; parse via regex.
- Missing workspace ID or usage fields should raise parse errors.
- Cookie import defaults to Chrome-only to avoid extra browser prompts; pass a browser list to override.
- Set `CODEXBAR_OPENCODE_WORKSPACE_ID` to skip workspace lookup and force a specific workspace.
- Workspace override accepts a raw `wrk_…` ID or a full `https://opencode.ai/workspace/...` URL.
- Cached cookies: Keychain cache `com.steipete.codexbar.cache` (account `cookie.opencode`, source + timestamp). Browser
  import only runs when the cached cookie fails.
