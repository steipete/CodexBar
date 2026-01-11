---
summary: "Gemini provider data sources: OAuth-backed quota APIs, token refresh, and tier detection."
read_when:
  - Debugging Gemini quota fetch or auth issues
  - Updating Gemini CLI OAuth integration
  - Adjusting tier detection or model mapping
---

# Gemini provider

Gemini uses the Gemini CLI OAuth credentials and private quota APIs. No browser cookies.

## Data sources + fallback order

1) **OAuth-backed quota API** (only path used in `fetch()`)
   - Reads auth type from `~/.gemini/settings.json`.
   - Supported: `oauth-personal` (or unknown → try OAuth creds).
   - Unsupported: `api-key`, `vertex-ai` (hard error).

2) **Legacy CLI parsing** (parser exists but not used in current fetch path)
   - `GeminiStatusProbe.parse(text:)` can parse `/stats` output.

## OAuth credentials
- File: `~/.gemini/oauth_creds.json`.
- Required fields: `access_token`, `refresh_token` (optional), `id_token`, `expiry_date`.
- If access token is expired, we refresh via Google OAuth using client ID/secret extracted
  from the Gemini CLI install (see below).

## OAuth client ID/secret extraction
- We locate the installed `gemini` binary, then search for:
  - Homebrew nested path:
    - `.../libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
  - Bun/npm sibling path:
    - `.../node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
- Regex extraction:
  - `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` from `oauth2.js`.

## API endpoints
- Quota:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Body: `{ "project": "<projectId>" }` (or `{}` if unknown)
  - Header: `Authorization: Bearer <access_token>`
- Project discovery:
  - `GET https://cloudresourcemanager.googleapis.com/v1/projects`
  - Picks `gen-lang-client*` or label `generative-language` for the project ID.
- Tier detection:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  - Body: `{ "metadata": { "ideType": "GEMINI_CLI", "pluginType": "GEMINI" } }`
- Token refresh:
  - `POST https://oauth2.googleapis.com/token`
  - Form body: `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`.

## Parsing + mapping
- Quota buckets:
  - `remainingFraction`, `resetTime`, `modelId`.
  - For each model, lowest `remainingFraction` wins.
  - `percentLeft = remainingFraction * 100`.
- Reset:
  - `resetTime` parsed as ISO-8601, formatted as "Resets in Xh Ym".
- UI mapping:
  - Primary: Pro models (lowest percent left).
  - Secondary: Flash models (lowest percent left).

## Plan detection
- Tier from `loadCodeAssist`:
  - `standard-tier` → "Paid"
  - `free-tier` + `hd` claim → "Workspace"
  - `free-tier` → "Free"
  - `legacy-tier` → "Legacy"
- Email from `id_token` JWT claims.

## Key files
- `Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`
