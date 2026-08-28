---
summary: "Factory (Droid) provider data sources: API key, browser cookies, WorkOS tokens, and Factory APIs."
read_when:
  - Debugging Factory/Droid usage fetch
  - Updating Factory cookie, API key, or WorkOS token handling
  - Adjusting Factory provider UI/menu behavior
---

# Factory (Droid) provider

Factory (displayed as "Droid") supports API-key and web-based auth. Source mode can be `auto`, `api`, or `web`.

## Data sources + fallback order

### API (`api`)
1. Resolve a Factory API key from, in order:
   - `~/.codexbar/config.json` `providers[].apiKey` for `factory` (also via Settings or
     `codexbar config set-api-key --provider factory`)
   - `FACTORY_API_KEY`
   - optional `~/.factory/.env` (`FACTORY_API_KEY=…` or `export FACTORY_API_KEY=…`)
2. Call Factory APIs with `Authorization: Bearer <apiKey>` (same billing-limits / bearer path as session tokens).

### Web (`web`)
Fetch attempts run in this exact order:
1) **Cached cookie header** (Keychain cache `com.steipete.codexbar.cache`, account `cookie.factory`).
2) **Stored session** (`~/Library/Application Support/CodexBar/factory-session.json`).
3) **Stored bearer token** (same session file).
4) **Stored WorkOS refresh token** (same session file).
5) **Local storage WorkOS tokens** (Safari + Chrome/Chromium/Arc leveldb).
6) **Browser cookies (Safari only)** for Factory domains.
7) **WorkOS cookies (Safari)** to mint tokens.
8) **Browser cookies (Chrome, Firefox)** for Factory domains.
9) **WorkOS cookies (Chrome, Firefox)** to mint tokens.

If a step succeeds, we cache cookies/tokens back into the session store.

Manual option:
- Preferences → Providers → Droid → Cookie source → Manual.
- Paste the `Cookie:` header from app.factory.ai.

### Auto (`auto`)
1. Try API first when a key is resolvable.
2. Fall back to web strategies on missing/unauthorized keys and other recoverable API failures
   (timeouts, DNS/network errors, 5xx, parse failures). Cancellation does not fall back.
3. Explicit `api` mode stays strict and does not fall back to web.
4. When both an API key and a browser/WorkOS session are available, Auto may surface the API-key
   account rather than the browser session. Use explicit `web` (or `api`) to pin account precedence.

## Settings
- Preferences → Providers → Droid:
  - Usage source: `Auto`, `API key`, `Browser cookies`
  - API key: optional override for `FACTORY_API_KEY` / `~/.factory/.env`
  - Cookie source: Automatic / Manual (web path)

## CLI
```bash
printf '%s' "$FACTORY_API_KEY" | codexbar config set-api-key --provider factory --stdin
codexbar usage --provider factory --source api
codexbar usage --provider factory --source web
```

## Cookie import
- Cookie domains: `factory.ai`, `app.factory.ai`, `auth.factory.ai`.
- Cookie names considered a session:
  - `wos-session`
  - `__Secure-next-auth.session-token`
  - `next-auth.session-token`
  - `__Secure-authjs.session-token`
  - `__Host-authjs.csrf-token`
  - `authjs.session-token`
  - `session`
  - `access-token`
- Stale-token retry filters:
  - `access-token`, `__recent_auth`.

## Base URL selection
- Candidates are tried in order (deduped):
  - `https://auth.factory.ai`
  - `https://api.factory.ai`
  - `https://app.factory.ai`
  - `baseURL` (default `https://app.factory.ai`)
- Cookie domains influence candidate ordering (auth domain first if present).

## Factory API endpoints
All requests set:
- `Accept: application/json`
- `Content-Type: application/json`
- `Origin: https://app.factory.ai`
- `Referer: https://app.factory.ai/`
- `x-factory-client: web-app`
- `Authorization: Bearer <token>` when a bearer token / API key is available.
- `Cookie: <session cookies>` when cookies are available.

Endpoints:
- `GET https://api.factory.ai/api/billing/limits`
  - Preferred when the account uses token-rate-limits billing (5h / weekly / monthly windows).
- `GET <baseURL>/api/app/auth/me`
  - Returns org + subscription metadata + feature flags.
- `GET <baseURL>/api/organization/subscription/usage`
  - Query: `useCache=true` and optional `userId`
  - Returns Standard + Premium token usage and billing window.

## WorkOS token minting
- Endpoint:
  - `POST https://api.workos.com/user_management/authenticate`
- Body:
  - `client_id`: one of
    - `client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7`
    - `client_01HNM792M5G5G1A2THWPXKFMXB`
  - `grant_type`: `refresh_token`
  - `refresh_token`: from local storage or session store
  - Optional: `organization_id`
  - When using cookies: `useCookie: true` + `Cookie: <workos.com cookies>`

## Local storage WorkOS token extraction
- Safari:
  - Root: `~/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default`
  - Finds `origin` files containing `app.factory.ai` or `auth.factory.ai`, then reads
    `LocalStorage/localstorage.sqlite3`.
- Chrome/Chromium/Arc/Helium:
  - Roots under `~/Library/Application Support/<Browser>/User Data/<Profile>/Local Storage/leveldb`.
  - Helium uses `~/Library/Application Support/net.imput.helium/<Profile>/Local Storage/leveldb` (no `User Data`).
  - Scans LevelDB files for `workos:refresh-token` and `workos:access-token`.
- Parsed tokens:
  - `workos:refresh-token` (required)
  - `workos:access-token` (optional)
  - Organization ID parsed from JWT when available.

## Session storage
- File: `~/Library/Application Support/CodexBar/factory-session.json`
- Stores cookies + bearer token + WorkOS refresh token.

## Snapshot mapping
- Token-rate-limits accounts: primary 5h, secondary weekly, tertiary monthly (+ optional Core windows).
- Legacy Standard/Premium accounts: primary Standard, secondary Premium; reset at billing period end.
- Plan/tier + org name from auth response.

## Troubleshooting
- Missing API key: set `FACTORY_API_KEY`, Settings → Droid → API key, or `codexbar config set-api-key --provider factory`.
- Unauthorized API key (401/403): regenerate at app.factory.ai/settings/api-keys.
- Missing session: log in to app.factory.ai in a supported browser, or paste a Cookie header in Manual mode.

## Key files
- `Sources/CodexBarCore/Providers/Factory/FactoryProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Factory/FactorySettingsReader.swift`
- `Sources/CodexBarCore/Providers/Factory/FactoryStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Factory/FactoryLocalStorageImporter.swift`
