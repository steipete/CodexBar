---
summary: "Codebuff provider data sources: API token, CLI credentials file, credit balance, and weekly rate limits."
read_when:
  - Debugging Codebuff credential resolution or usage parsing
  - Updating Codebuff credit balance or weekly rate-limit display
  - Adjusting Codebuff provider UI/menu behavior
---

# Codebuff

CodexBar surfaces [Codebuff](https://www.codebuff.com) credit balance and
weekly rate limits next to your other AI providers.

## Data sources

- `POST https://www.codebuff.com/api/v1/usage` — current credit usage,
  remaining balance, auto top-up state, and the next quota reset date.
- `GET  https://www.codebuff.com/api/user/subscription` — subscription tier,
  billing period end, and the weekly rate-limit window (`weeklyUsed` /
  `weeklyLimit`) when CodexBar is using the CLI credentials-file session token.

Both endpoints use a Bearer token. Codebuff credentials come from the
environment, the normal CodexBar config file, or the official CLI credentials
file; the Codebuff provider does not write a separate Keychain credential.

## Authentication

CodexBar resolves the Codebuff API token in this order:

1. `CODEBUFF_API_KEY` environment variable (takes precedence so CI overrides
   work). API-key tokens fetch credit balance only.
2. The per-provider API key stored in Settings → Providers → Codebuff (saved
   in `~/.codexbar/config.json` via the normal CodexBar config flow). API-key
   tokens fetch credit balance only.
3. `~/.config/manicode/credentials.json` — the file the official `codebuff`
   CLI (formerly `manicode`) writes after `codebuff login`. CodexBar reads
   `default.authToken`, falling back to top-level `authToken`, and uses that
   session token for both credit balance and subscription metadata.

If none of those is available, Codebuff shows the “missing token” error.

## Credit window mapping

- **Primary row** — credit balance (`usage / quota`), with the "next quota
  reset" date if provided.
- **Secondary row** — weekly rate-limit window (`weeklyUsed / weeklyLimit`)
  shown with a 7-day window.

The account panel shows the Codebuff tier (e.g. "Pro"), remaining balance,
and whether auto top-up is enabled.

## Troubleshooting

- Run `codebuff login` to refresh `~/.config/manicode/credentials.json`.
- Override the API base with `CODEBUFF_API_URL` for staging environments.
- Verify your token works manually:

  ```sh
  curl -s -X POST -H "Authorization: Bearer $CODEBUFF_API_KEY" \
    -H 'Content-Type: application/json' -d '{"fingerprintId":"codexbar-usage"}' \
    https://www.codebuff.com/api/v1/usage
  ```

## Related files

- `Sources/CodexBarCore/Providers/Codebuff/` — descriptor, fetcher, snapshot,
  settings reader, error types.
- `Sources/CodexBar/Providers/Codebuff/` — settings store bridge + macOS
  settings pane implementation.
- `Tests/CodexBarTests/CodebuffSettingsReaderTests.swift`,
  `CodebuffUsageFetcherTests.swift`, and the Codebuff extensions in
  `ProviderTokenResolverTests.swift`.
