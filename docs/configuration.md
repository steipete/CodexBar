---
summary: "CodexBar config file layout for CLI + app settings."
read_when:
  - "Editing the CodexBar config file or moving settings off Keychain."
  - "Adding new provider settings fields or defaults."
  - "Explaining CLI/app configuration and security."
---

# Configuration

CodexBar reads a single JSON config file for CLI and app provider settings.
API keys, manual cookie headers, source selection, ordering, and token accounts live here. Keychain is still used for runtime cookie caches, browser Safe Storage access, and provider OAuth/device-flow credentials where those flows require it.

## Location
- `~/.codexbar/config.json`
- Override for scripts/tests: set `CODEXBAR_CONFIG=/path/to/config.json`.
- The directory is created if missing.
- Permissions are set to `0600` whenever CodexBar writes the file on macOS and Linux.

## Root shape
```json
{
  "version": 1,
  "providers": [
    {
      "id": "codex",
      "enabled": true,
      "source": "auto",
      "cookieSource": "auto",
      "cookieHeader": null,
      "apiKey": null,
      "enterpriseHost": null,
      "region": null,
      "workspaceID": null,
      "tokenAccounts": null,
      "subscriptionSnapshot": null
    }
  ]
}
```

## Provider fields
All provider fields are optional unless noted.

- `id` (required): provider identifier.
- `enabled`: enable/disable provider (defaults to provider default).
- `source`: preferred source mode.
  - `auto|web|cli|oauth|api`
  - `auto` uses provider-specific fallback order (see `docs/providers.md`).
  - `api` uses the provider's API-backed mode; only some providers consume the `apiKey` field.
- `apiKey`: raw API token for providers that support config-backed direct API usage.
- `enterpriseHost`: provider-specific API host/base URL override. Today this is used by Azure OpenAI, Copilot, and LLM Proxy.
- `cookieSource`: cookie selection policy.
  - `auto` (browser import), `manual` (use `cookieHeader`), `off` (disable cookies)
- `cookieHeader`: raw cookie header value (e.g. `key=value; other=...`).
- `region`: provider-specific region (e.g. `zai`, `minimax`).
- `workspaceID`: provider-specific workspace/deployment/project ID (e.g. Azure OpenAI deployment, OpenAI API project,
  `opencode`).
- `tokenAccounts`: multi-account tokens for providers in `TokenAccountSupportCatalog`.
- `subscriptionSnapshot`: optional Codex-only manual reminder metadata for local renewal/expiration reminders.

### manual `subscriptionSnapshot`
`subscriptionSnapshot` stores Codex manual reminder metadata for a local fallback. The first version is manual and Codex-only.

```json
{
  "provider": "codex",
  "planName": "Codex Plus",
  "status": "active",
  "subscriptionRenewsAt": "2026-06-24",
  "subscriptionExpiresAt": null,
  "source": "manual",
  "confidence": "manual",
  "updatedAt": "2026-05-24T00:00:00Z"
}
```

Notes:
- This is local-only manual metadata. CodexBar does not sync it from Codex and it only affects menu display and reminder notifications on the current Mac.
- This is not quota reset timing and does not change usage-window math.
- Renewal/expiry values are calendar days (`YYYY-MM-DD`), not timestamps.
- The in-app UI intentionally saves only the minimal fallback reminder semantics: renewal dates save as `active`,
  expiry dates save as `canceled`, and the UI does not edit `planName`.
- If both renewal and expiry are set, expiry takes precedence for display and reminder evaluation.
- `source` and `confidence` are manual-only in this release.
- Leave both dates empty to disable the Codex reminder display.
- Automatic provider detection is intentionally out of scope here and should land in
  provider-specific PRs with redacted real samples.

Privacy boundary:
- No cookie reads for this feature.
- No billing-page scraping for this feature.
- No live provider billing/subscription endpoint calls for this feature.
- No raw billing/account response storage for this feature.

## Manual cookies
Use manual cookies when automatic browser import is unavailable, disabled, or too noisy for your setup.
The app and CLI both read the same `~/.codexbar/config.json`, so a manual cookie saved in the UI is also used by
`codexbar`, and a cookie written by tooling is shown in the app after reload.

`cookieHeader` expects the HTTP `Cookie:` request header value for the provider origin, not a raw Netscape cookie
export. In browser DevTools, open the Network tab, select a request for the provider site, and copy the request
header named `Cookie`. You can paste either the full `Cookie: name=value; other=value` string or just
`name=value; other=value`.

If you have a Netscape export, convert each non-comment row to `name=value` and join values with `; `. Do not paste
the raw `# Netscape HTTP Cookie File` text into `cookieHeader`.

Example placeholder config:

```json
{
  "version": 1,
  "providers": [
    {
      "id": "example-provider",
      "enabled": true,
      "cookieSource": "manual",
      "cookieHeader": "session=<REDACTED>; other=<REDACTED>"
    }
  ]
}
```

Validate after editing:

```bash
codexbar config validate
codexbar usage --provider example-provider --verbose
```

CLI shortcuts:

```bash
codexbar config providers
codexbar config enable --provider grok
codexbar config disable --provider cursor
printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
printf '%s' "$OPENAI_ADMIN_KEY" | codexbar config set-api-key --provider openai --stdin
printf '%s' "$GROQ_API_KEY" | codexbar config set-api-key --provider groq --stdin
printf '%s' "$LLM_PROXY_API_KEY" | codexbar config set-api-key --provider llmproxy --stdin
printf '%s' "$LITELLM_API_KEY" | codexbar config set-api-key --provider litellm --stdin
```

OpenAI API project scoping uses `workspaceID` in config. This maps to `OPENAI_PROJECT_ID` for Admin API usage and is
only applied to the configured OpenAI key, not to selected OpenAI token accounts:

```json
{
  "id": "openai",
  "enabled": true,
  "apiKey": "<OPENAI_ADMIN_KEY>",
  "workspaceID": "proj_..."
}
```

LLM Proxy also needs a base URL. Set `enterpriseHost` in config or `LLM_PROXY_BASE_URL` in the process environment:

```json
{
  "id": "llmproxy",
  "enabled": true,
  "apiKey": "<REDACTED>",
  "enterpriseHost": "https://proxy.example.com"
}
```

LiteLLM also needs a base URL. Set `enterpriseHost` in config or `LITELLM_BASE_URL` in the process environment:

```json
{
  "id": "litellm",
  "enabled": true,
  "apiKey": "<REDACTED>",
  "enterpriseHost": "https://litellm.example.com"
}
```

See [CLI configuration](cli-configuration.md) for scripting examples and output formats.

Manual cookies are secrets. Keep `~/.codexbar/config.json` private, leave its permissions at `0600`, never commit it,
and never paste real cookie values or readable DevTools screenshots into public issues.

### tokenAccounts
```json
{
  "version": 1,
  "activeIndex": 0,
  "accounts": [
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "label": "user@example.com",
      "token": "sk-...",
      "addedAt": 1735123456,
      "lastUsed": 1735220000
    }
  ]
}
```

## Provider IDs
Current IDs (see `Sources/CodexBarCore/Providers/Providers.swift`):
`codex`, `openai`, `azureopenai`, `claude`, `cursor`, `opencode`, `opencodego`, `alibaba`, `alibabatokenplan`, `factory`, `gemini`, `antigravity`, `copilot`, `devin`, `zai`, `minimax`, `manus`, `kimi`, `kilo`, `kiro`, `vertexai`, `augment`, `jetbrains`, `kimik2`, `moonshot`, `amp`, `t3chat`, `ollama`, `synthetic`, `warp`, `openrouter`, `elevenlabs`, `windsurf`, `perplexity`, `mimo`, `doubao`, `abacus`, `mistral`, `deepseek`, `codebuff`, `crof`, `venice`, `commandcode`, `stepfun`, `bedrock`, `grok`, `groq`, `llmproxy`, `litellm`, `deepgram`.

## Ordering
The order of `providers` controls display/order in the app and CLI. Reorder the array to change ordering.

## Notes
- Fields not relevant to a provider are ignored.
- Omitted providers are appended with defaults during normalization.
- Keep the file private; it contains secrets.
- Validate the file with `codexbar config validate` (JSON output available with `--format json`).
