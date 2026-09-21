---
summary: "Muse Code authentication, subscription windows, and local token history."
read_when:
  - Configuring Muse Code in CodexBar
  - Debugging Muse Code login or subscription usage errors
---

# Muse Code

CodexBar shows Muse Code subscription usage and local token history. Subscription quota comes from the bundled JavaScript provider; token history comes from the Muse CLI's session logs. Dollar costs remain unavailable because those logs do not provide billing amounts.

## Authentication

Sign in with the Muse CLI:

```bash
muse login
```

CodexBar reads the same Keychain item the CLI stores (`ai.meta.dev.credentials` / `meta`) and sends only the device-code `dca:` access token to `POST https://api.meta.ai/muse-code/key`. Meta dashboard `LLM_` keys and Muse-minted `LLM|` inference keys cannot read this quota (they 401 on that mint endpoint).

Credential precedence: when `providers.meta.access_token` is present inline in the CLI metadata file `~/.config/muse/auth.json`, that token selects the account queried and takes precedence over Keychain. Otherwise CodexBar reads the device-code token from the CLI's Keychain item. An `auth.json` with `"mechanism": "oauth"` but no inline token still counts as a login; the token then comes from Keychain. Override the file path with `MUSE_AUTH_PATH` if needed. CodexBar never prompts Keychain.

## Data shown

The bundled `muse.ts` plugin owns the JSON request and subscription parsing on macOS and Linux. Native code only
reads the CLI-owned credential and registers the provider. The returned inference key and payment metadata are
discarded; CodexBar never writes them to the CLI's credential store.

- Plan name from `subs_tier_name` (for example Muse Code Power Usage).
- 5-hour window percent, duration, and `resets_at`.
- Weekly window percent and `resets_at`.

Reset timestamps outside the supported date range are omitted without discarding the window's usage percentage.

Pay-as-you-go accounts without `is_subs_active` are reported as having no subscription rather than a fake 0% bar. Accounts that still need a payment method are reported as billing-incomplete.

## Local token history

Enable local usage tracking to show today's tokens, recent daily history, and token comparisons below the subscription windows. The command `codexbar cost --provider muse` also reports tokens; its JSON keeps unavailable monetary fields absent. Local history requires no provider request, credential access, or pricing download.

The reader uses `$MUSE_SESSIONS_DIR`, or `$XDG_DATA_HOME/muse/sessions` (default `~/.local/share/muse/sessions`). It reads `YYYY/MM/DD/session/session.jsonl` files and buckets turns by their recorded timestamp in the local calendar, including turns written after a session's directory date. This is machine-local history across the selected session tree, not an account billing statement or a quota estimate.

Only `model_completed` and `automated_review_completed` inference records count. Tokens total input plus output; cached and reasoning counters are subsets, so they are not added again. CPU telemetry, child rollups, and goal attribution do not duplicate usage. Unknown models keep their recorded token totals and remain unpriced.

Scans are bounded to 30 seconds and 2 GiB of newly read data per refresh, with per-file and per-line bounds. Newly parsed events within the requested dates have a separate 16 MiB conservative size budget, and caches have a 64 MiB limit checked before JSON encoding. Completed files are cached by file identity and precise timestamps; subsequent refreshes can reach additional files without rereading unchanged logs. Interrupted files restart on the next refresh. Changed roots, requested date ranges, calendars, and timezones invalidate cached bucketing. Corrupt records, unsupported usage shapes, unreadable files, and exhausted budgets produce explicitly partial or unavailable history, preserving valid recorded subtotals. An unavailable day is never presented as a measured zero.

## Privacy

The mint response can include a card brand/last-four `payment_method` field. CodexBar does not display it. Email and plan stay on the Muse identity card.
