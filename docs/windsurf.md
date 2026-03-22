---
summary: "Windsurf provider data sources: Firebase IndexedDB tokens, local SQLite cache, and GetPlanStatus API."
read_when:
  - Debugging Windsurf usage fetch
  - Updating Windsurf Firebase token import or API handling
  - Adjusting Windsurf provider UI/menu behavior
---

# Windsurf provider

Windsurf supports two data sources: a web API (via Firebase tokens from browser IndexedDB) and a local SQLite cache.

## Data sources + fallback order

Usage source picker:
- Preferences → Providers → Windsurf → Usage source (Auto / Web API / Local).

### Auto mode (default)
1) **Web API** (preferred) — real-time data from windsurf.com API.
2) **Local SQLite cache** (fallback) — reads from Windsurf's `state.vscdb`.

### Web API fetch order
1) **Manual token** (when Cookie source = Manual).
2) **Cached Firebase access token** (Keychain cache `com.steipete.codexbar.cache`, account `cookie.windsurf`).
3) **Browser IndexedDB import** — extracts Firebase tokens from Chromium browsers.

### Local SQLite cache
- File: `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`.
- Key: `windsurf.settings.cachedPlanInfo` in `ItemTable`.
- Limitation: only updates when Windsurf is launched; can be significantly stale.

## Cookie source settings

Preferences → Providers → Windsurf → Cookie source:

- **Automatic** (default): imports Firebase tokens from browser IndexedDB, caches access tokens in Keychain.
- **Manual**: paste a Firebase refresh token or access token directly (see below).
- **Off**: disables web API access entirely; only local SQLite cache is used.

### How to get a manual token

1. Open `https://windsurf.com/subscription/usage` in Chrome or Edge and sign in.
2. Open Developer Tools (F12 or Cmd+Option+I).
3. Go to the **Console** tab.
4. Paste the following JavaScript and press Enter:

```javascript
(async () => {
  const dbs = await indexedDB.databases();
  const fbDb = dbs.find(d => d.name === 'firebaseLocalStorageDb');
  if (!fbDb) { console.log('Not signed in'); return; }
  const db = await new Promise((r, e) => {
    const req = indexedDB.open(fbDb.name);
    req.onsuccess = () => r(req.result);
    req.onerror = () => e(req.error);
  });
  const tx = db.transaction('firebaseLocalStorage', 'readonly');
  const store = tx.objectStore('firebaseLocalStorage');
  const all = await new Promise(r => {
    const req = store.getAll();
    req.onsuccess = () => r(req.result);
  });
  const entry = all.find(e => e.value?.stsTokenManager);
  if (entry) {
    const mgr = entry.value.stsTokenManager;
    console.log('=== Refresh token (long-lived, recommended) ===');
    console.log(mgr.refreshToken);
    console.log('=== Access token (expires ~1h) ===');
    console.log(mgr.accessToken);
  } else {
    console.log('No Firebase token found. Sign in to windsurf.com first.');
  }
})();
```

5. Copy the **refresh token** (starts with `AMf-vB`, long-lived) from the console output.
6. In CodexBar: Providers → Windsurf → Cookie source → Manual → paste the token.

**Note**: Both token types are accepted. Refresh tokens (`AMf-vB…`) are recommended — they persist across sessions and CodexBar will automatically exchange them for short-lived access tokens. Access tokens (`eyJ…`) expire after ~1 hour.

## Authentication flow (Automatic mode)

```
Browser IndexedDB (LevelDB on disk)
    ↓ extract Firebase refreshToken (prefix: AMf-vB...)
POST https://securetoken.googleapis.com/v1/token
    ↓ exchange for accessToken (JWT, ~1h expiry)
POST https://windsurf.com/_backend/.../GetPlanStatus
    ↓ body: { authToken, includeTopUpStatus: true }
UsageSnapshot (daily/weekly quota %)
```

## Firebase token extraction

- **Browsers scanned**: Chrome, Edge, Brave, Arc, Vivaldi, Chromium, and other Chromium forks.
- **IndexedDB path**: `~/Library/Application Support/<Browser>/<Profile>/IndexedDB/https_windsurf.com_*.indexeddb.leveldb/`
- **Token patterns**:
  - Refresh token: `AMf-vB` prefix (Google Identity Toolkit format).
  - Access token: `eyJ` prefix (JWT).
- **Extraction methods** (in order):
  1. `ChromiumLocalStorageReader.readTextEntries()` (structured LevelDB read).
  2. `ChromiumLocalStorageReader.readTokenCandidates()` (raw token scan).
  3. Direct `.ldb`/`.log` file scan with regex (fallback).

## API endpoints

### Firebase token refresh
- `POST https://securetoken.googleapis.com/v1/token?key=AIzaSyDsOl-1XpT5err0Tcnx8FFod1H8gVGIycY`
- Content-Type: `application/x-www-form-urlencoded`
- Body: `grant_type=refresh_token&refresh_token=<token>`
- Returns: `{ "access_token": "...", "expires_in": "3600", ... }`

### GetPlanStatus (ConnectRPC over JSON)
- `POST https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus`
- Headers:
  - `Content-Type: application/json`
  - `Connect-Protocol-Version: 1`
- Body: `{ "authToken": "<accessToken>", "includeTopUpStatus": true }`
- Response:
```json
{
  "planStatus": {
    "planInfo": { "planName": "Pro", "teamsTier": "TEAMS_TIER_PRO" },
    "planStart": "2026-03-20T18:05:50Z",
    "planEnd": "2026-04-20T18:05:50Z",
    "dailyQuotaRemainingPercent": 68,
    "weeklyQuotaRemainingPercent": 84,
    "dailyQuotaResetAtUnix": "1774166400",
    "weeklyQuotaResetAtUnix": "1774166400"
  }
}
```

## Snapshot mapping
- Primary: daily usage percent (100 - dailyQuotaRemainingPercent).
- Secondary: weekly usage percent (100 - weeklyQuotaRemainingPercent).
- Reset: daily/weekly reset timestamps (Unix seconds as string).
- Plan: planName from planInfo.
- Expiry: planEnd date.

## Troubleshooting

### "No Firebase token found in browser IndexedDB"
- Sign in to `https://windsurf.com` in Chrome, Edge, or another Chromium browser.
- Grant Full Disk Access to CodexBar (System Settings → Privacy & Security → Full Disk Access).
- Try Manual mode and paste the token directly.

### "Firebase token refresh failed"
- Your refresh token may have expired. Sign in to windsurf.com again in your browser.
- Check your internet connection.

### "Windsurf API call failed: HTTP 401"
- The access token has expired. CodexBar will automatically refresh it on the next fetch.
- If using Manual mode, paste a fresh access token.

### Stale data with Local mode
- The local SQLite cache only updates when Windsurf is launched. Switch to Auto or Web API mode for real-time data.

## Key files
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfStatusProbe.swift` (local SQLite)
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfFirebaseTokenImporter.swift` (IndexedDB extraction)
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfWebFetcher.swift` (token refresh + API)
- `Sources/CodexBarCore/Providers/Windsurf/WindsurfProviderDescriptor.swift` (fetch strategies)
- `Sources/CodexBar/Providers/Windsurf/WindsurfProviderImplementation.swift` (settings UI)
- `Sources/CodexBar/Providers/Windsurf/WindsurfSettingsStore.swift` (settings persistence)
