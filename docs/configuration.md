---
summary: "CodexBar config file layout for CLI + app settings."
read_when:
  - "Editing the CodexBar config file or moving settings off Keychain."
  - "Adding new provider settings fields or defaults."
  - "Explaining CLI/app configuration and security."
---

# Configuration

CodexBar reads a single JSON config file for CLI and app settings.
Secrets (API keys, cookies, tokens) live here; Keychain is not used.

## Location
- `~/.codexbar/config.json`
- The directory is created if missing.
- Permissions are forced to `0600` on macOS and Linux.

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
  - `api` uses provider API key flow (when supported).
- `apiKey`: raw API token for providers that support direct API usage.
- `cookieSource`: cookie selection policy.
  - `auto` (browser import), `manual` (use `cookieHeader`), `off` (disable cookies)
- `cookieHeader`: raw cookie header value (e.g. `key=value; other=...`).
- `region`: provider-specific region (e.g. `zai`, `minimax`).
- `workspaceID`: provider-specific workspace ID (e.g. `opencode`).
- `tokenAccounts`: multi-account tokens for a provider.

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
`codex`, `claude`, `cursor`, `opencode`, `factory`, `gemini`, `antigravity`, `copilot`, `zai`, `minimax`, `kimi`, `kiro`, `vertexai`, `augment`, `jetbrains`, `kimik2`, `amp`, `synthetic`.

## Ordering
The order of `providers` controls display/order in the app and CLI. Reorder the array to change ordering.

## Notes
- Fields not relevant to a provider are ignored.
- Omitted providers are appended with defaults during normalization.
- Keep the file private; it contains secrets.
- Validate the file with `codexbar config validate` (JSON output available with `--format json`).
