---
summary: "Gemini CLI OAuth quotas and opt-in Gemini app web usage limits."
read_when:
  - Debugging Gemini quota fetch or auth issues
  - Updating Gemini CLI OAuth integration
  - Adjusting tier detection or model mapping
---

# Gemini provider

Choose **Gemini CLI** (the default) or **Gemini app** under Settings → Providers → Gemini → Usage source.
They measure different quotas and may use different Google accounts. Changing the source clears the previous
quota display. Antigravity remains a separate provider.

## Data sources

- **Gemini CLI** uses local CLI OAuth credentials and the quota API described below. `auto` and `api` select this
  path; they never fall back to a browser account. API-key and Vertex AI auth types are unsupported here.
- **Gemini app** is an explicit `web` source for the 5-hour and weekly limits shown at
  [gemini.google.com/usage](https://gemini.google.com/usage). Select Automatic cookies to use the shared browser
  order, or Manual to paste a Cookie header. Login opens that usage page. The app source does not require Gemini CLI.
- **Legacy CLI parsing** remains available to parser callers through `GeminiStatusProbe.parse(text:)`; the fetch
  pipeline does not scrape `/stats`.

## Gemini app request and account selection

The bundled `gemini-web` plugin sends a cookie-authenticated GET to
`https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery`.
The public `UsagePageSurface` JavaScript bundle identifies the persisted `UsagePageQuery` signature as
`2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g=` and its variables as:

```json
{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"workspaceRequest":{"recommendationsForSurfaceRequests":[]}}
```

The response's `data.viewer.rpcs.getUsageInfo.pools` contains `GXU_FIVE_HOURLY` and `GXU_WEEKLY` entries.
`percentageUsed` is a fraction; `gxu.windowRefreshesAt` supplies the reset time. Missing or invalid values remain
unavailable, while a reported zero stays zero. The app's subscription tier comes from this response; CLI account
identity and plan data are never copied into the app result.

Cookie values stay opaque to the plugin and are scoped to the Gemini request URL. Imported browser sessions are not
written to a cookie cache; a manually entered Cookie header follows the existing local settings storage policy.
The shared browser gate forbids prompts during background or settings refreshes, checks matching cookie rows before
Safe Storage access, and applies the manual-action prompt budget and denial cooldown. Signed-out candidates can be
skipped; the first validated account ends traversal, even when it reports no supported quota windows. Query drift
fails visibly instead of silently switching accounts or reusing CLI quotas.

```sh
codexbar usage --provider gemini --source web --json
```

## OAuth credentials
- File: `~/.gemini/oauth_creds.json`.
- Required fields: `access_token`, `refresh_token` (optional), `id_token`, `expiry_date`.
- If access token is expired, we refresh via Google OAuth using client ID/secret extracted
  from the Gemini CLI install (see below).

## OAuth client ID/secret extraction
- Resolution order:
  1. `GEMINI_OAUTH_CLIENT_ID` + `GEMINI_OAUTH_CLIENT_SECRET` environment override.
  2. `GEMINI_OAUTH2_JS_PATH` pointing at a readable `oauth2.js` file.
  3. Installed Gemini CLI package (`oauth2.js` / bundle regex extraction).
  4. Known global Gemini CLI install paths (Homebrew npm prefix layouts, then
     Homebrew Cellar/`opt` `libexec` package roots when the GUI cannot resolve
     the `gemini` binary).
- We locate the installed `gemini` binary, then search for:
  - Homebrew nested path:
    - `.../libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
  - Homebrew Cellar/opt package root (no-binary fallback):
    - `/opt/homebrew/Cellar/gemini-cli/<version>/libexec/lib/node_modules/@google/gemini-cli`
    - `/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli`
    - same under `/usr/local`
  - Bun/npm sibling path:
    - `.../node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
- Regex extraction:
  - `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` from `oauth2.js` or Homebrew bundle chunks.

## API endpoints
- Quota:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Body: `{ "project": "<projectId>" }` (or `{}` if unknown)
  - Header: `Authorization: Bearer <access_token>`
- Project discovery (quota project ID):
  - Primary: `cloudaicompanionProject` from `loadCodeAssist`.
  - Fallback: `GET https://cloudresourcemanager.googleapis.com/v1/projects`
    - Picks `gen-lang-client*` or label `generative-language`.
- Tier detection:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  - Body: `{ "metadata": { "ideType": "GEMINI_CLI", "pluginType": "GEMINI" } }`
- Token refresh:
  - `POST https://oauth2.googleapis.com/token`
  - Form body: `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`.
  - Values are form-encoded so literal plus signs, separators, and percent escapes remain intact.

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
  - Tertiary: Flash Lite models (lowest percent left).
  - Automatic shows the first exhausted tier when present; otherwise it prefers Pro, then Flash, then Flash Lite,
    even when a later tier has a higher used percentage.
  - Missing model tiers remain absent. The shared menu-bar metric fallback uses Flash Lite when both Pro and Flash
    are unavailable, including Automatic, Pro, Flash, and Average. Average still combines Pro and Flash when both exist.

## Plan detection
- Tier from `loadCodeAssist`:
  - `paidTier.name` → paid subscription label from Google, preferred whenever present
  - `standard-tier` → "Paid" (fallback when `paidTier.name` is absent)
  - `free-tier` + `hd` claim → "Workspace" (fallback when `paidTier.name` is absent)
  - `free-tier` → "Free"
  - `legacy-tier` → "Legacy"
- Email from `id_token` JWT claims.

## Consumer-tier migration (June 2026)
- [Google stopped serving](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)
  Gemini CLI OAuth for individual, AI Pro, and Ultra accounts on 2026-06-18. Standard and Enterprise
  subscriptions remain supported; paid API-key access is outside CodexBar's OAuth-backed Gemini provider.
- When quota, `loadCodeAssist`, or token-refresh responses include Google's unsupported-client
  migration signal (`UNSUPPORTED_CLIENT`, `IneligibleTierError`, or Antigravity migration copy),
  CodexBar surfaces `consumerTierDeprecated` with guidance to use the Antigravity provider.
- Google's live shape is an HTTP **200** `loadCodeAssist` body with no `currentTier` and the consumer tier
  listed under `ineligibleTiers[].reasonCode == "UNSUPPORTED_CLIENT"`; the follow-up `retrieveUserQuota`
  call then fails with HTTP 403 `SUBSCRIPTION_REQUIRED` and no migration wording. CodexBar reads the
  200 body's `ineligibleTiers` directly, and maps that 403 to `consumerTierDeprecated` only when the same
  fetch saw the unsupported-client flag **and** the account is not on `standard-tier` — a licensed
  account's 403 stays `HTTP 403`.
- The unsupported-client flag itself is suppressed for accounts the shutdown does not cover: a named
  `paidTier.name` (authoritative even without `currentTier`) and an `hd` claim (Workspace/education, which
  `resolveAccountPlan` reads as Workspace when paired with `free-tier`). Both would otherwise be pre-empted
  by the earlier `loadCodeAssist` branch, which runs before the plan resolver.
- `UsageStore.geminiMigrationObservation` records which sentinel the last refresh produced
  (`none` / `localAntigravityHandoff` / `googleConsumerTierShutdown`); a later local-tooling failure never
  downgrades a shutdown already seen. `geminiObservedConsumerTierDeprecation` (either sentinel) drives the
  settings action; the narrower `geminiObservedGoogleConsumerTierShutdown` drives the login guard. While
  the narrow one is set **for this session**,
  the Gemini login action stops clearing `~/.gemini/oauth_creds.json` and launching Gemini CLI — whose
  OAuth step fails with the same message — and shows the Antigravity guidance instead. The local
  `oauthCredentialsUnavailableWithAntigravity` handoff deliberately does not guard login: there,
  reinstalling or relaunching Gemini CLI is the fix, and Workspace accounts must keep that path.
- The guard warns rather than blocks: its alert offers **Switch Account…** next to Cancel (Cancel is the
  default, since confirming clears credentials). Confirming re-runs the ordinary login without the guard,
  which is how a user moves from a shut-down consumer account to a Workspace, education, or Code Assist
  Standard/Enterprise one. The observation is not cleared by confirming, so the settings action stays put
  and the next attempt warns again.
- Settings shows an **Enable Antigravity provider** action only after CodexBar observes
  `consumerTierDeprecated` during a Gemini refresh (typed sentinel state, not user-facing text matching).
- The action is explicit: CodexBar never automatically enables Antigravity or falls back to it.
- Ordinary Gemini login, `notLoggedIn`, and Antigravity setup errors remain unchanged. CodexBar does not
  capture Terminal `gemini` OAuth output, so Terminal-only failures cannot activate the migration action.
- Workspace and education Google accounts are outside the June 2026 consumer shutdown; keep using the
  Gemini provider. Antigravity remains the consumer replacement path for individual, AI Pro, and Ultra.

## Key files
- `Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`
