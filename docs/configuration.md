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
      "region": null,
      "workspaceID": null,
      "tokenAccounts": null
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
- `cookieSource`: cookie selection policy.
  - `auto` (browser import), `manual` (use `cookieHeader`), `off` (disable cookies)
- `cookieHeader`: raw cookie header value (e.g. `key=value; other=...`).
- `region`: provider-specific region (e.g. `zai`, `minimax`).
- `workspaceID`: provider-specific workspace ID (e.g. `opencode`).
- `tokenAccounts`: multi-account tokens for providers in `TokenAccountSupportCatalog`.

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
`codex`, `claude`, `cursor`, `opencode`, `opencodego`, `alibaba`, `factory`, `gemini`, `antigravity`, `copilot`, `zai`, `minimax`, `kimi`, `kilo`, `kiro`, `vertexai`, `augment`, `jetbrains`, `kimik2`, `amp`, `ollama`, `synthetic`, `warp`, `openrouter`, `perplexity`, `abacus`, `mistral`, `deepseek`, `codebuff`, `commandcode`.

## Ordering
The order of `providers` controls display/order in the app and CLI. Reorder the array to change ordering.

## Notes
- Fields not relevant to a provider are ignored.
- Omitted providers are appended with defaults during normalization.
- Keep the file private; it contains secrets.
- Validate the file with `codexbar config validate` (JSON output available with `--format json`).
