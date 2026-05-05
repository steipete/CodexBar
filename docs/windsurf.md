---
summary: "Windsurf provider data sources: browser localStorage session import, local SQLite cache, and GetPlanStatus protobuf API."
read_when:
  - Debugging Windsurf usage fetch
  - Updating Windsurf web session import or API handling
  - Adjusting Windsurf provider UI/menu behavior
---

# Windsurf provider

Windsurf supports two data sources: a web API backed by the current website session, and a local SQLite cache.

## Data sources + fallback order

Usage source picker:
- Preferences → Providers → Windsurf → Usage source (Auto / Web API / Local).

### Auto mode (default)
1) **Web API** (preferred) — real-time data from windsurf.com.
2) **Local SQLite cache** (fallback) — reads from Windsurf's `state.vscdb`.

### Web API fetch order
1) **Manual session bundle** (when Cookie source = Manual).
2) **Browser localStorage import** — extracts the active `devin_*` session values from Chromium browsers.

### Local SQLite cache
- File: `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`.
- Key: `windsurf.settings.cachedPlanInfo` in `ItemTable`.
- Newer cache shapes may omit `quotaUsage` but include `usage` counters. In that case CodexBar derives
  usage windows from `usedMessages/messages` and `usedFlowActions/flowActions`.
- Limitation: only updates when Windsurf is launched; can be significantly stale.

## Cookie source settings

Preferences → Providers → Windsurf → Cookie source:

- **Automatic** (default): imports the active Windsurf session bundle from Chromium browser localStorage.
- **Manual**: paste a JSON bundle with `devin_session_token`, `devin_auth1_token`, `devin_account_id`, and `devin_primary_org_id`.
- **Off**: disables web API access entirely; only local SQLite cache is used.

### How to get a manual session bundle

1. Open [windsurf.com/profile](https://windsurf.com/profile) in Chrome or Edge and sign in.
2. Open Developer Tools (`F12` or `Cmd+Option+I`).
3. Go to the **Console** tab.
4. Paste the following JavaScript and press Enter:

```javascript
(() => {
  const keys = [
    "devin_session_token",
    "devin_auth1_token",
    "devin_account_id",
    "devin_primary_org_id",
  ];

  const read = (key) => {
    const value = localStorage.getItem(key);
    if (!value) return null;
    try {
      return JSON.parse(value);
    } catch {
      return value;
    }
  };

  const payload = Object.fromEntries(keys.map((key) => [key, read(key)]));
  const missing = keys.filter((key) => !payload[key]);

  if (missing.length > 0) {
    console.log("Missing Windsurf session keys:", missing.join(", "));
    return;
  }

  const json = JSON.stringify(payload, null, 2);
  console.log(json);
  if (typeof copy === "function") {
    copy(json);
    console.log("Copied Windsurf session bundle to clipboard.");
  }
})();
```

5. Copy the JSON output.
6. In CodexBar: Providers → Windsurf → Cookie source → Manual → paste the JSON bundle.

## Authentication flow (Automatic mode)

```text
Browser localStorage (leveldb on disk)
    ↓ extract devin_session_token / devin_auth1_token / devin_account_id / devin_primary_org_id
POST https://windsurf.com/_backend/.../GetPlanStatus
    ↓ headers: x-auth-token + x-devin-*
    ↓ protobuf body: { auth_token, include_top_up_status: true }
UsageSnapshot (daily/weekly quota %)
```

## Browser session extraction

- **Browsers scanned**: Chrome, Edge, Brave, Arc, Vivaldi, Chromium, and compatible Chromium forks.
- **Local storage path**: `~/Library/Application Support/<Browser>/<Profile>/Local Storage/leveldb/`
- **Origin**: `https://windsurf.com`
- **Required keys**:
  - `devin_session_token`
  - `devin_auth1_token`
  - `devin_account_id`
  - `devin_primary_org_id`

## API endpoint

### GetPlanStatus (ConnectRPC over protobuf)
- `POST https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus`
- Headers:
  - `Content-Type: application/proto`
  - `Connect-Protocol-Version: 1`
  - `Origin: https://windsurf.com`
  - `Referer: https://windsurf.com/profile`
  - `x-auth-token: <devin_session_token>`
  - `x-devin-session-token: <devin_session_token>`
  - `x-devin-auth1-token: <devin_auth1_token>`
  - `x-devin-account-id: <devin_account_id>`
  - `x-devin-primary-org-id: <devin_primary_org_id>`
- Protobuf request fields:
  - `1 auth_token: string`
  - `2 include_top_up_status: bool`
- Parsed response fields used by CodexBar:
  - `plan_status.plan_info.plan_name`
  - `plan_status.plan_end`
  - `plan_status.daily_quota_remaining_percent`
  - `plan_status.weekly_quota_remaining_percent`
  - `plan_status.daily_quota_reset_at_unix`
  - `plan_status.weekly_quota_reset_at_unix`

## Snapshot mapping
- Web primary: daily usage percent (`100 - daily_quota_remaining_percent`).
- Web secondary: weekly usage percent (`100 - weekly_quota_remaining_percent`).
- Local primary: daily quota percent when present; otherwise message usage (`usedMessages/messages`).
- Local secondary: weekly quota percent when present; otherwise flow-action usage (`usedFlowActions/flowActions`).
- Reset: daily/weekly reset timestamps (Unix seconds), when available.
- Plan: `plan_status.plan_info.plan_name`.
- Expiry: `plan_status.plan_end`.

## Troubleshooting

### "No Windsurf web session found in Chromium localStorage"
- Sign in to [windsurf.com](https://windsurf.com) in Chrome, Edge, or another Chromium browser.
- Grant Full Disk Access to CodexBar (System Settings → Privacy & Security → Full Disk Access).
- Try Manual mode and paste the JSON session bundle directly.

### "Invalid Windsurf session payload"
- The manual value must include all four keys: `devin_session_token`, `devin_auth1_token`, `devin_account_id`, and `devin_primary_org_id`.
- Re-run the console snippet on a logged-in `windsurf.com` page.

### "Windsurf API call failed: HTTP 401"
- The imported browser session is stale or invalid.
- Refresh the Windsurf page in your browser and try again.
- If using Manual mode, paste a fresh JSON bundle.

### Stale data with Local mode
- The local SQLite cache only updates when Windsurf is launched. Switch to Auto or Web API mode for real-time data.

## Key files
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfStatusProbe.swift` (local SQLite)
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfDevinSessionImporter.swift` (Chromium localStorage extraction)
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfWebFetcher.swift` (protobuf request + response parsing)
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfProviderDescriptor.swift` (fetch strategies)
- `Sources/CodexBar/Providers/Windsurf/WindsurfProviderImplementation.swift` (settings UI)
- `Sources/CodexBar/Providers/Windsurf/WindsurfSettingsStore.swift` (settings persistence)
