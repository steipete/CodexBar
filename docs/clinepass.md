---
summary: "ClinePass API-key or browser sign-in setup and five-hour, weekly, and monthly subscription limits."
read_when:
  - Configuring ClinePass usage tracking
  - Debugging ClinePass credentials or usage-limit parsing
---

# ClinePass

ClinePass tracks subscription quota, separate from Cline pay-as-you-go balances. Enable it in Settings → Providers
and add an API key, or sign in with your browser via `cline auth` (no API key needed):

```bash
printf '%s' "$CLINE_API_KEY" | codexbar config set-api-key --provider clinepass --stdin
# or browser sign-in (writes ~/.cline/data/settings/providers.json, reused automatically):
cline auth
```

The CLI accepts `CLINE_API_KEY` or `CLINEPASS_API_KEY` from its environment, in that order, then falls back to the
`cline` OAuth session in Cline's `providers.json` (`workos:` bearer token, shared by `cline` and `cline-pass`).
Explicit API keys take precedence over the browser session. Source modes are `auto` and `api`; both use the same
bundled provider plugin on macOS and Linux.

## Data source

The plugin sends a bearer-authenticated `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits` request.
Reported `five_hour`, `weekly`, and `monthly` limits map to the primary, secondary, and tertiary windows.
Each window uses the returned `percentUsed` and optional `resetsAt`; absent windows remain unavailable.
This endpoint does not provide pay-as-you-go balances or local cost history.

```bash
codexbar usage --provider clinepass --source api --format json --pretty
```

## Implementation

- `Sources/CodexBarCore/Providers/ClinePass/ClinePassProviderDescriptor.swift` owns metadata and source selection.
- `Sources/CodexBarCore/Providers/ClinePass/ClinePassSettingsReader.swift` resolves environment keys and the `cline auth`
  browser session (`~/.cline/data/settings/providers.json`, `workos:` bearer token).
- `Sources/CodexBarCore/Resources/Plugins/clinepass.ts` owns the request and response mapping; its JavaScript is generated.
