---
summary: "Factory (Droid) provider data sources: browser cookies, WorkOS tokens, and Factory APIs."
read_when:
  - Debugging Factory/Droid usage fetch
  - Updating Factory cookie or WorkOS token handling
  - Adjusting Factory provider UI/menu behavior
---

# Factory (Droid) provider

Factory (displayed as "Droid") is web-based. We authenticate via cookies or WorkOS tokens and call Factory APIs.

## Data sources + fallback order

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
- `Authorization: Bearer <token>` when a bearer token is available.
- `Cookie: <session cookies>` when cookies are available.

Endpoints:
- `GET <baseURL>/api/app/auth/me`
  - Returns org + subscription metadata + feature flags.
- `POST <baseURL>/api/organization/subscription/usage`
  - Body: `{ "useCache": true, "userId": "<id?>" }`
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
- Primary: Standard usage ratio.
- Secondary: Premium usage ratio.
- Reset: billing period end date.
- Plan/tier + org name from auth response.

## Key files
- `Sources/CodexBarCore/Providers/Factory/FactoryStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Factory/FactoryLocalStorageImporter.swift`
