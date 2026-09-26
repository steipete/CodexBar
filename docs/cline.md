---
summary: "Cline usage-billing API-key or browser sign-in setup and pay-as-you-go credit balance."
read_when:
  - Configuring Cline usage tracking
  - Debugging Cline credentials or balance parsing
---

# Cline

Cline tracks pay-as-you-go credit balances, separate from ClinePass subscription quota. Enable it in Settings → Providers
and add an API key, or sign in with your browser via `cline auth` (no API key needed):

```bash
printf '%s' "$CLINE_API_KEY" | codexbar config set-api-key --provider cline --stdin
# or browser sign-in (writes ~/.cline/data/settings/providers.json, reused automatically):
cline auth
```

The CLI accepts `CLINE_API_KEY` or `CLINEPASS_API_KEY` from its environment, in that order, then falls back to the
`cline` OAuth session in Cline's `providers.json` (`workos:` bearer token, shared by `cline` and `cline-pass`).
Explicit API keys take precedence over the browser session. Source modes are `auto` and `api`; both use the same
bundled provider plugin on macOS and Linux.

## Data source

The plugin sends bearer-authenticated requests to Cline's account API:

1. `GET https://api.cline.bot/api/v1/users/me` → resolves the user id and account email.
2. `GET https://api.cline.bot/api/v1/users/{id}/balance` → pay-as-you-go credit balance (reported in cents,
   displayed as dollars).

```bash
codexbar usage --provider cline --source api --format json --pretty
```

## Implementation

- `Sources/CodexBarCore/Providers/Cline/ClineProviderDescriptor.swift` owns metadata and source selection.
- `Sources/CodexBarCore/Providers/Cline/ClineSettingsReader.swift` resolves environment keys and the `cline auth`
  browser session (`~/.cline/data/settings/providers.json`, `workos:` bearer token).
- `Sources/CodexBarCore/Resources/Plugins/cline.ts` owns the request and response mapping; its JavaScript is generated.
