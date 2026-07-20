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
- `CODEXBAR_CONFIG=/path/to/config.json` when set.
- `$XDG_CONFIG_HOME/codexbar/config.json` when `XDG_CONFIG_HOME` is set to an absolute path. Relative values are
  ignored.
- `~/.config/codexbar/config.json` by default for new installs.
- `~/.codexbar/config.json` for existing legacy installs when no XDG config exists.
- The directory is created if missing.
- Permissions are set to `0600` whenever CodexBar writes the file on macOS and Linux.

## Root shape
```json
{
  "version": 1,
  "hooks": null,
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
      "tokenAccounts": null
    }
  ]
}
```

## External event hooks

Hooks are local, explicit opt-in automation. Configure them in Settings > Hooks or in this local config file; no
HTTP or remote-config endpoint can create or enable hook rules. The top-level `hooks.enabled` switch defaults to
`false`, and each rule also has its own `enabled` switch.

```json
{
  "hooks": {
    "enabled": true,
    "events": [
      {
        "id": "quota-alert",
        "enabled": true,
        "event": "quota_low",
        "provider": "codex",
        "threshold": 0.9,
        "executable": "/usr/local/bin/quota-alert",
        "arguments": ["--message", "Codex quota is low", ""],
        "timeoutSeconds": 10
      }
    ]
  }
}
```

Commands run as direct executable invocations, never through a shell. `executable` must be an absolute path,
`arguments` preserves exact argument boundaries (including spaces and empty arguments), and `timeoutSeconds` must be
between `0.1` and `300`. Hook processes receive only a small allowlist of general environment variables plus the
event's `CODEXBAR_*` variables; CodexBar provider keys and tokens are not inherited. The same event is also encoded as
JSON on stdin. Only configure executables you trust.

Events:

- `quota_low`: a quota lane crosses the rule's `threshold` upward. Thresholds are usage fractions greater than `0`
  and at most `1`;
  rules without a threshold use the provider's configured warning thresholds.
- `quota_reached`: the primary session quota crosses into depletion.
- `quota_reset`: a confirmed session or weekly reset occurs.
- `provider_unavailable`: a provider status changes to a minor, major, or critical outage.
- `provider_recovered`: that tracked outage returns to normal.
- `refresh_failed`: a provider refresh fails; `CODEXBAR_STATUS` is a coarse category such as `timeout`, `offline`,
  `network_error`, `auth_required`, `cancelled`, or `error`.

`provider_unavailable` and `refresh_failed` are coalesced per provider/account/window for ten minutes so background
refresh failures cannot create command storms. Quota and recovery events use their transition detectors instead. Hook
failures are contained and never block provider refresh.

Payload environment variables are `CODEXBAR_EVENT`, `CODEXBAR_PROVIDER`, `CODEXBAR_TIMESTAMP`, and, when available,
`CODEXBAR_ACCOUNT`, `CODEXBAR_WINDOW`, `CODEXBAR_USAGE_PERCENT`, `CODEXBAR_USED`, `CODEXBAR_LIMIT`,
`CODEXBAR_RESET_AT`, and `CODEXBAR_STATUS`. Enabling Hide personal info omits `CODEXBAR_ACCOUNT` and the matching JSON
field.

The stdin JSON uses the same camel-case field names without the `CODEXBAR_` prefix. Dates are UTC ISO 8601 strings,
usage percentages are `0...1` fractions, unavailable optional fields are omitted rather than encoded as `null`, and
keys are emitted in sorted order. A `quota_reached` payload is exactly shaped like this (the timestamps vary):

```json
{"event":"quota_reached","provider":"claude","resetAt":"2023-11-14T22:13:20Z","timestamp":"2023-11-14T22:15:00Z","usagePercent":0.42,"window":"session"}
```

The v1 field names and meanings are compatibility-stable. Hook consumers should ignore unknown fields so CodexBar can
add optional observability data without breaking existing commands.

Safety limits: at most 32 rules, 32 arguments per rule, 4 KiB per executable or argument string, 32 KiB per command,
and 4 KiB per event payload. Configurations beyond these limits fail closed and do not execute.

## Provider fields
All provider fields are optional unless noted.

- `id` (required): provider identifier.
- `enabled`: enable/disable provider (defaults to provider default).
- `source`: preferred source mode.
  - `auto|web|cli|oauth|api`
  - `auto` uses provider-specific fallback order (see `docs/providers.md`).
  - `api` uses the provider's API-backed mode; only some providers consume the `apiKey` field.
- `apiKey`: raw API token for providers that support config-backed direct API usage.
- `enterpriseHost`: provider-specific API host/base URL override. Used by Azure OpenAI, Copilot, LLM Proxy, LiteLLM,
  ClawRouter, and Wayfinder.
- `cookieSource`: cookie selection policy.
  - `auto` (browser import), `manual` (use `cookieHeader`), `off` (disable cookies)
- `cookieHeader`: raw cookie header value (e.g. `key=value; other=...`).
- `region`: provider-specific region (e.g. `zai`, `minimax`).
- `workspaceID`: provider-specific workspace/deployment/project ID (e.g. Azure OpenAI deployment, OpenAI API project,
  `opencode`).
- `tokenAccounts`: multi-account tokens for providers in `TokenAccountSupportCatalog`.
- `claudeSwapEnabled`: allow the Claude provider to read account usage from claude-swap.
- `claudeSwapExecutablePath`: path to the `cswap` executable.
- `claudeSwapShowSingleAccount`: prefer a claude-swap card when exactly one account is available. Defaults to
  `false`; multiple claude-swap accounts retain their existing precedence.

## Manual cookies
Use manual cookies when automatic browser import is unavailable, disabled, or too noisy for your setup.
The app and CLI both read the same resolved config file, so a manual cookie saved in the UI is also used by
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
printf '%s' "$CLAWROUTER_API_KEY" | codexbar config set-api-key --provider clawrouter --stdin
printf '%s' "$SUB2API_API_KEY" | codexbar config set-api-key --provider sub2api --stdin
printf '%s' "$AIAND_API_KEY" | codexbar config set-api-key --provider aiand --stdin
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

ClawRouter defaults to the hosted service. To use another deployment, set `enterpriseHost` in config or
`CLAWROUTER_BASE_URL` in the process environment:

```json
{
  "id": "clawrouter",
  "enabled": true,
  "apiKey": "<REDACTED>",
  "enterpriseHost": "https://router.example.com"
}
```

sub2api needs its self-hosted base URL. Set `enterpriseHost` in config or `SUB2API_BASE_URL` in the process
environment. Add labeled token accounts in Settings when one deployment has multiple group API keys:

```json
{
  "id": "sub2api",
  "enabled": true,
  "apiKey": "<REDACTED>",
  "enterpriseHost": "https://sub2api.example.com"
}
```

See [CLI configuration](cli-configuration.md) for scripting examples and output formats.

Manual cookies are secrets. Keep the CodexBar config file private, leave its permissions at `0600`, never commit it,
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

z.ai team accounts also use `usageScope`, `organizationId`, and `workspaceID`; see [z.ai](zai.md).

## Provider IDs
Current IDs (see `Sources/CodexBarCore/Providers/Providers.swift`):
`codex`, `openai`, `azureopenai`, `claude`, `clinepass`, `cursor`, `opencode`, `opencodego`, `alibaba`, `alibabatokenplan`, `factory`, `gemini`, `antigravity`, `copilot`, `devin`, `zai`, `minimax`, `manus`, `kimi`, `kilo`, `kiro`, `vertexai`, `augment`, `jetbrains`, `moonshot`, `amp`, `t3chat`, `ollama`, `synthetic`, `warp`, `openrouter`, `elevenlabs`, `windsurf`, `zed`, `perplexity`, `mimo`, `doubao`, `sakana`, `abacus`, `mistral`, `deepseek`, `deepinfra`, `codebuff`, `crof`, `venice`, `commandcode`, `qoder`, `stepfun`, `bedrock`, `grok`, `groq`, `llmproxy`, `litellm`, `deepgram`, `poe`, `chutes`, `neuralwatt`, `clawrouter`, `longcat`, `sub2api`, `wayfinder`, `zenmux`, `aiand`.

## Ordering
The order of `providers` controls display/order in the app and CLI. Reorder the array to change ordering.

## Notes
- Fields not relevant to a provider are ignored.
- Omitted providers are appended with defaults during normalization.
- Keep the file private; it contains secrets.
- Validate the file with `codexbar config validate` (JSON output available with `--format json`).
