---
summary: "ClinePass API-key setup and five-hour, weekly, and monthly subscription limits."
read_when:
  - Configuring ClinePass usage tracking
  - Debugging ClinePass credentials or usage-limit parsing
---

# ClinePass

ClinePass tracks subscription quota, separate from Cline pay-as-you-go balances. Enable it in Settings → Providers
and add an API key, or store the key through the shared CLI configuration:

```bash
printf '%s' "$CLINE_API_KEY" | codexbar config set-api-key --provider clinepass --stdin
```

The CLI also accepts `CLINE_API_KEY` or `CLINEPASS_API_KEY` from its environment, in that order. Source modes are
`auto` and `api`; both use the same bundled provider plugin on macOS and Linux.

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
- `Sources/CodexBarCore/Providers/ClinePass/ClinePassSettingsReader.swift` resolves environment keys.
- `Sources/CodexBarCore/Resources/Plugins/clinepass.ts` owns the request and response mapping; its JavaScript is generated.
