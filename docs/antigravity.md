---
summary: "Antigravity provider notes: OAuth usage, multi-account switching, local LSP probing, and quota parsing."
read_when:
  - Adding or modifying the Antigravity provider
  - Debugging Antigravity port detection or quota parsing
  - Adjusting Antigravity menu labels or model mapping
  - Working with Antigravity OAuth or account switching
---

# Antigravity provider

For Google individual, AI Pro, and Ultra accounts blocked by the June 2026 Gemini CLI OAuth
shutdown, Antigravity is the replacement path for Gemini quota tracking in CodexBar. Launch
the Antigravity app or run `agy`, sign in, then refresh. See `docs/gemini.md` for the Gemini
provider migration notes. CodexBar offers the handoff only after an observed Google migration
signal and never enables or falls back to Antigravity automatically.

To use the `agy` CLI source without keeping the desktop app open, install the CLI first
(`brew install --cask antigravity-cli`; use `ANTIGRAVITY_CLI_PATH` when it is not on PATH), then
run `agy` once and sign in. CodexBar keeps the signed-in `agy` local HTTPS server alive briefly
after each refresh and stops it when idle, or reuses a signed-in `agy` you already have running
without taking ownership of that process.

Antigravity supports four usage data sources:

1. The Antigravity 2.0 app's local `language_server` (preferred when the app is open).
2. The `agy` CLI's embedded HTTPS localhost server (preferred over the IDE because it exposes richer quota data).
3. The Antigravity IDE extension `language_server` (used after `agy` CLI because current IDE local payloads only expose session/model quota data).
4. Google OAuth-backed remote usage (explicit OAuth mode, and the account-scoped fallback used for multi-account switching). The OAuth path can store multiple Google accounts through the shared token-account switcher.

## When the Antigravity app is closed

The app-local `language_server` exists only while Antigravity.app is running. With the app closed,
CodexBar relies on the `agy` CLI HTTPS source or the Google OAuth fallback. Without a signed-in
`agy`, the OAuth fallback can only prove model availability, so the menu shows an all-100%
placeholder instead of real quota numbers. A freshly spawned `agy` needs a few seconds for macOS
keyring authentication before its quota endpoints answer, so the first refresh after a cold start
can take a few extra seconds while CodexBar waits for readiness; later refreshes reuse the warmed session.

The local and CLI paths both prefer Antigravity's internal `RetrieveUserQuotaSummary` quota payload and may fall back to
`GetUserStatus`, then `GetCommandModelConfigs`; CodexBar never scrapes the desktop UI or the `agy` TUI.

As of Antigravity 2.x, the Antigravity app and `agy` CLI payloads can be richer than Google OAuth and IDE payloads.
`RetrieveUserQuotaSummary` exposes the same two groups shown by Antigravity's Model Quota UI:

- `Gemini Models`: weekly limit and five-hour limit.
- `Claude and GPT models`: weekly limit and five-hour limit.

Older local payloads may only include raw Claude, GPT-OSS, Gemini tiers, account plan, and session reset timestamps.
Current Antigravity IDE local endpoints return `GetUserStatus`, `GetAvailableModels`, and `GetCascadeModelConfigData`
with five-hour/session reset data, but not the app/CLI `RetrieveUserQuotaSummary` weekly/session grouping. OAuth
payloads can be less complete and may only prove model availability. Treat `auto` as the authoritative user-facing mode:
it accepts the first account-matching source in Antigravity app -> `agy` CLI -> Antigravity IDE order, and adds OAuth
when CodexBar has a selected/injected Google account or an existing shared credentials file. An all-100%
`fetchAvailableModels` payload is only accepted after `retrieveUserQuota` echoes bucket fractions; this can be an
availability-style fallback rather than the full Antigravity quota summary.
When OAuth identifies the account but quota endpoints deny access, CodexBar shows `Limits not available` instead of an
empty quota card.

## OAuth account switching

- Login still uses Antigravity's Google OAuth client, discovered from `Antigravity.app` or overridden with `ANTIGRAVITY_OAUTH_CLIENT_ID` and `ANTIGRAVITY_OAUTH_CLIENT_SECRET`.
- A successful login writes the latest shared credentials to `~/.codexbar/antigravity/oauth_creds.json` and upserts a token-account entry for the Google account.
- Each token-account entry stores serialized `AntigravityOAuthCredentials` and is injected into remote fetches through `ANTIGRAVITY_OAUTH_CREDENTIALS_JSON`.
- When a token account is selected, the OAuth fetcher uses that account before falling back to the shared credentials file.
  In `auto` mode the ambient Antigravity app, `agy` CLI, and IDE probes still run first, but a snapshot whose account
  does not match the selected account is rejected so the pipeline falls through to the account-scoped OAuth fetch (see
  `AntigravitySelectedAccountGuard`). If no account is selected/injected, `auto` includes OAuth only when the legacy
  shared credentials file already exists. Explicit `cli`/`oauth` source modes stay authoritative and are not re-checked.
- Removing the last saved token account that matches `~/.codexbar/antigravity/oauth_creds.json` deletes that shared file,
  so a removed CodexBar account does not silently continue refreshing through the legacy shared cache.
- The menu action is labeled `Add Account...`; switching between saved accounts scopes Google OAuth fetches.

## Remote OAuth data sources

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:onboardUser`
- `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` (available, but current observed OAuth
  responses are model-bucket shaped rather than Antigravity 2.0's two quota groups)

## Data sources + fallback order

### 1) Antigravity app local probe

When the Antigravity 2.0 app is running:

1. **Process detection**
   - Command: `ps -ax -o pid=,command=`.
   - The app local strategy scopes detection to the **Antigravity app** language server only
     (`AntigravityStatusProbe(processScope: .appOnly)`). It deliberately does **not**
     attach to an IDE or `agy` CLI process: a lower-information IDE payload should not mask
     `agy`'s richer quota summary, and a stale or still-initializing `agy` can accept the
     connection before it is ready. `agy` is owned exclusively by the CLI HTTPS source below,
     which waits for real API readiness. The probe still classifies all kinds
     (`processInfo(scope: .ideAndCLI)` is used by `isRunning()` for status reporting):
     - the **Antigravity app** language server: process names such as `language_server`, `language_server_macos`,
       `language_server_macos_arm`, or `language-server` plus
       Antigravity markers (`--app_data_dir antigravity`, an Antigravity app bundle path,
       or a path containing `/antigravity/`); or
     - the **IDE** language server: the Antigravity IDE extension language server, usually under
       `Antigravity IDE.app/.../extensions/antigravity/bin/` with `--app_data_dir antigravity-ide`; or
     - the **CLI**: an `antigravity-cli` / `antigravity_cli` path segment, or the
       `agy` binary (path-anchored so unrelated arguments/binaries do not match).
   - CodexBar collects all valid local app language-server candidates and probes each reachable one. If multiple
     app processes are open, it prefers the richer quota-summary snapshot over the legacy `GetUserStatus`
     two-pool fallback.
   - Extract CLI flags:
     - `--csrf_token <token>`. Requirement depends on the match kind:
       - **App/IDE** matches still require it - a tokenless desktop language-server match is
         skipped so a later valid server can be found, otherwise `missingCSRFToken`
         is reported (unchanged behavior).
       - **CLI** matches accept an empty token, because the CLI's language server
         exposes no `--csrf_token` flag and requires none.
     - `--extension_server_port <port>` (HTTP fallback; app/IDE only).
     - `--extension_server_csrf_token <token>` (preferred HTTP fallback token when present).

2. **Port discovery**
   - macOS uses kernel process-socket enumeration.
   - Linux tries `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>`, then process-scoped `/proc` discovery if
     `lsof` is missing, fails to launch or exits unsuccessfully, or reports no listeners. Namespace warnings from
     `lsof` therefore do not prevent discovery when `/proc` remains readable. Cancellation and hard subprocess limits
     still propagate. If neither source finds a listener, CLI readiness polling continues within its existing deadline
     and retains the last discovery diagnostic if startup never succeeds. An endpoint readiness failure takes
     precedence once a listener has been reached.
   - `/proc/<pid>/fd` socket inodes are matched only against the same process's `net/tcp` and `net/tcp6` tables.
   - All listening ports are probed.

3. **Connect port probe (HTTPS)**
   - `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUnleashData`
   - Headers:
     - `X-Codeium-Csrf-Token: <token>`
     - `Connect-Protocol-Version: 1`
   - First 200 OK response selects the connect port.

4. **Quota fetch**
   - Primary:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
   - Fallback 1:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/GetUserStatus`
   - Fallback 2:
     - `POST https://127.0.0.1:<connectPort>/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs`
   - If HTTPS fails, retry over HTTP on `extension_server_port`.

### 2) `agy` CLI HTTPS source

When source mode is `auto` or `cli` and the desktop local probe fails, CodexBar resolves `agy` via:

- `ANTIGRAVITY_CLI_PATH`
- `PATH` / login-shell path lookup
- Well-known paths:
  - `~/.local/bin/agy`
  - `/opt/homebrew/bin/agy`
  - `/usr/local/bin/agy`

CodexBar launches `agy` in a PTY because the CLI exposes its quota server only while the interactive process is alive.
The implementation still does **not** scrape terminal output; it only keeps the process alive, drains discarded PTY
rendering, uses the same platform-specific port discovery described above, and probes the local HTTPS server:

- First: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
- Fallback 1: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus`
- Fallback 2: `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs`

The fallback can return quota without the account email or plan fields from `GetUserStatus`.

Differences from the desktop local probe:

- The CLI HTTPS endpoint does **not** require `X-Codeium-Csrf-Token`.
- Before launching `agy`, both menu-bar refreshes and one-shot CLI invocations spend at most two seconds looking for
  an already-running, same-user `agy` at the selected binary path and reuse its tokenless local HTTPS endpoint when it
  returns parseable usage for the selected account. CodexBar-owned pids are excluded from external reuse so managed
  probe/idle lifecycle accounting stays balanced; if no eligible external server answers, CodexBar uses its managed
  session as before.
- On macOS, external reuse matches the selected binary against the kernel executable path, not the spelling of
  `argv[0]`; a bare `agy` command can match, but a conflicting executable cannot. Platforms without that identity
  retain the absolute command-path check. User/account and managed-process exclusions are unchanged.
- If `agy` is signed out, an unavailable or tokenless IDE fallback keeps the actionable Terminal sign-in guidance.
  A successful fallback still supplies usage, and more specific later errors retain their normal precedence.
- Readiness is endpoint-based: CodexBar retries until one of the quota endpoints parses, because fresh `agy`
  processes can bind a port before the quota service is initialized.
- App runtime uses a bounded warm session: `agy` is kept alive briefly after a refresh, then stopped on idle. CLI runtime
  tears it down immediately after the one-shot fetch.
- Repeated endpoint failures force a relaunch instead of reusing a wedged process forever.
- CodexBar records the launched pid + executable identity and conservatively reaps only its own matching stale `agy`
  process on the next launch. It never blind-kills a user-launched `agy`.

### 3) Antigravity IDE local probe

When the Antigravity 2.0 app and `agy` CLI are unavailable, CodexBar probes Antigravity IDE language servers with
`AntigravityStatusProbe(processScope: .ideOnly)`. Current observed IDE payloads return model-level/session quota data
through `GetUserStatus`, `GetAvailableModels`, and `GetCascadeModelConfigData`; `RetrieveUserQuotaSummary` returns 404
from the IDE local server. This means the IDE fallback can show session bars, but should not be expected to provide the
weekly limit shown by Antigravity 2.0.

### 4) OAuth remote fallback

When source mode is `auto`, OAuth is used after app, `agy` CLI, and IDE paths fail if CodexBar has a selected/injected
Google account or an existing shared credentials file. The app, `agy` CLI, and IDE probes still run first, but in
`auto` mode their snapshots are accepted only when the reported account matches the selected account; otherwise the
pipeline falls through to this account-scoped OAuth fetch. When source mode is `oauth`, only OAuth is used and the
shared OAuth file can still be used as a fallback credential source.

## Request body (summary)
- Minimal metadata payload:
  - `ideName: antigravity`
  - `extensionName: antigravity`
  - `locale: en`
  - `ideVersion: unknown`

## Parsing and model mapping
- Preferred source fields:
  - `response.groups[].displayName`
  - `response.groups[].buckets[].bucketId`
  - `response.groups[].buckets[].displayName`
  - `response.groups[].buckets[].remaining.remainingFraction`
  - `response.groups[].buckets[].description`
- Legacy source fields:
  - `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.remainingFraction`
  - `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.resetTime`
- Preferred quota summary UI:
  - Render `Gemini Session`, `Gemini Weekly`, `Claude + GPT Session`, and `Claude + GPT Weekly` as named windows.
  - Keep Antigravity's bucket description as reset prose; infer `windowMinutes` from the bucket ID/display name.
  - Use the most constrained known bucket as the compact/menu-bar metric.
- Legacy user-facing quota groups:
  - `Gemini` groups Gemini Pro and Gemini Flash text models.
  - `Claude + GPT` groups Claude text models and GPT/GPT-OSS text models.
- Representative selection:
  - Hidden model rows such as Lite, autocomplete, and image variants do not drive summary bars.
  - For each group, CodexBar uses the lowest remaining known quota row and preserves that row's reset metadata.
  - Rows with reset metadata but no remaining fraction stay visible as unavailable reset context only when their group
    has no known usage row.
- `resetTime` parsing:
  - ISO-8601 preferred; numeric epoch seconds as fallback.
- Identity:
  - `accountEmail` and `planName` only from `GetUserStatus`.

## UI mapping
- Provider metadata:
  - Display: `Antigravity`
  - Labels: `Gemini` (primary), `Claude + GPT` (secondary)
- Status badge: Google Workspace incidents for the Gemini product.
- Antigravity exposes many model rows, but current local payloads show them collapsing into two real usage pools:
  Gemini and Claude/GPT. Detailed usage should not list every raw Gemini tier unless a future source exposes a genuinely
  distinct unknown or consumed quota window.
- Some Antigravity local/CLI model config entries include reset metadata but omit `remainingFraction`. Those windows stay
  in `extraRateWindows` for reset context and are marked with `usageKnown: false`; clients should not render their
  `usedPercent` as a real exhausted quota.
- Menu-bar layout Session and Weekly tokens independently select the most constrained known quota-summary row for
  each cadence across model families. They do not use the Gemini and Claude/GPT family representatives, which can
  represent different cadences. Unknown or missing summary cadences remain unavailable; snapshots without summary
  rows retain the standard cadence fallback. Automatic selection, its exhausted-quota option, and explicit family
  metrics retain their existing selection policies.
- Antigravity reports every model family the plan covers, so an account that only uses Gemini still receives a
  Claude/GPT pair pinned at 0%. Menu cards and widgets hide a family once every lane in it reports known zero usage.
  A family with unknown usage stays visible, and every family remains visible when all are untouched, for example
  right after a weekly reset. Provider details is the diagnostic surface and always lists every family, the same
  principle it already applies to cost data. The filter is display-only: the snapshot, CLI output, and menu-bar
  ranking still see every window, and menu-bar selection ranks by highest used, so an untouched family never wins.
- The dashboard-v1 payload keeps every family for its script clients and marks the lanes of an untouched family with
  `idle` instead. The `codexbar serve` web UI skips those rows, so the web card matches the menu without repeating
  the family rule in JavaScript. See `docs/dashboard-api.md`.

## Local token history

Local history reads only the existing recognized roots: `~/.gemini/antigravity-cli/conversations/*.db`,
`~/.gemini/antigravity/*.db`, and `~/.gemini/antigravity/conversations/*.db`. `GEMINI_CLI_HOME` replaces
`~/.gemini`. When SQLite discovery completes without any databases, the reader can use
`~/.config/tokscale/antigravity-cache/sessions/*.jsonl`; `TOKSCALE_CONFIG_DIR` replaces `~/.config/tokscale`.
Both overrides and `HOME` come from the same refresh environment. Declared roots and session files may be symlinks;
discovery still visits only the immediate entries of the recognized directories. This is machine-local token history,
not account attribution or dollar pricing. No language server, provider CLI, browser, credentials, or network is used.

Use `codexbar cost --provider antigravity --format json` to read this same local history from the CLI.
The cost endpoint and dashboard also include it when Antigravity is selected. Token counts do not imply known dollar
costs, and these entry points do not expand the supported timestamp layouts described below.

SQLite is authoritative when present. An unreadable root, malformed database, unsupported event layout, or exhausted
budget never authorizes replacement by a smaller/stale JSONL cache. Complete empty databases and complete histories
outside the selected window establish empty history; absent sources and partial scans do not. Partial reports remain
diagnostic only: the fetcher withholds their rows. Regular refresh applies its existing failure/retention policy,
and neither regular refresh nor the dashboard publishes unavailable results as confirmed zero. Failed dashboard
attempts do not acknowledge successful incorporation of a refresh trigger.
Overflowed aggregate totals remain unknown rather than becoming saturated or wrapping.

The schema evidence is [Tokscale's pinned SQLite parser](https://github.com/junhoyeo/tokscale/blob/62ca1eb1677556972ba963fdfa3a41ab23c1eb4b/crates/tokscale-core/src/sessions/antigravity_cli.rs),
whose header records six databases and 140 turns. SQLite usage fields 1 + 2 are input, 5 is cache read,
9 is text output, and 10 is thinking output: text and thinking are separate counts. Historical model IDs are retained;
missing models stay unknown unless an unambiguous raw label maps to a model within the same session.
Conflicting mappings remain unresolved. Every repeated known protobuf envelope is validated and merged.
The supported database layout is an ordinary `gen_metadata` table with stored `idx` and `data` columns.
Extra ordinary columns and `WITHOUT ROWID` tables are supported; views, virtual tables, and generated/hidden columns
are rejected before querying payloads. Schema inspection and the payload scan share one read transaction.
Inspection uses `sqlite_master` and `table_xinfo`; SQLite builds without that pragma cannot establish coverage.
Aggregate conversation rows without generation payloads are ignored.

Supported SQLite event time is either:
- Legacy absolute timestamps in `chatModel.#9.#4` (`1.9.4`, seconds/nanos).
- Modern relative elapsed milliseconds in `chatModel.#9.#10` (`1.9.10.1`, 0 when omitted) added to the
  `trajectory_metadata_blob.#2` (`2.1`/`2.2`) base timestamp, used by `agy` 1.1.18+.

Missing or malformed timestamps mark event coverage partial. File modification and refresh times are never substitutes.

SQLite session identity is the original database filename stem, with `gen_metadata.idx` identifying rows. Copies
retaining that session name deduplicate across recognized roots; ID-less rows at different indices remain distinct.
Response IDs deduplicate only within a session, after successful validation and aggregation. Conflicting copies mark
coverage partial. Arbitrarily renamed copies cannot be identified by this schema and are not supported as copies;
the reader never guesses identity from equal token payloads.

The [separate JSONL producer](https://github.com/junhoyeo/tokscale/blob/62ca1eb1677556972ba963fdfa3a41ab23c1eb4b/crates/tokscale-cli/src/antigravity.rs)
records `sessionId`, retry `outputTokens` as `output`, and `thinkingOutputTokens` as `reasoning`. These recorded buckets
do not establish whether output already includes thinking. JSONL with nonzero reasoning therefore remains unsupported
until that relationship is independently established; neither adding nor subtracting it is assumed. JSONL requires a session identity and a finite,
exact integer usage timestamp. Numeric lexemes are checked before Foundation decoding can round them: counters must
be exact nonnegative integers through `Int.max`, and timestamps must be positive integers through 253402300799999 ms.
Whole decimal/exponent equivalents and signed zero are accepted without floating-point conversion; fractional,
underflowing, overflowing, boolean, or quoted-number values are not. Top-level keys must be unique, including escaped
equivalents. Session metadata can supply a model, never a missing usage timestamp. The producer
prefers usage time but can fall back to session start, so its reported dates may be imprecise. The reader honors
explicit usage timestamps, including equality with session start: equality does not distinguish a legitimate first
generation from the producer's fallback. Identical session/line
copies deduplicate, while contradictory copies remain partial.

One cancellable job on `CostUsageScanExecutor` owns discovery, SQL, decoding, and fallback. Limits are 500 files,
10,000 directory entries, 10,000 rows per file, 50,000 rows overall, 16 MiB per record, 64 MiB per file,
128 MiB of attempted payload bytes overall, and a five-second cooperative scan deadline. Rejected rows consume the budget;
exactly 500 complete databases are accepted. Discovery is incremental and JSONL is read in bounded chunks.
Schema inspection accepts at most 128 catalogue entries and 64 columns per database (one additional row detects
truncation), with a cumulative 64 KiB allowance for inspected schema text and the same cooperative deadline/cancellation.
SQLite values are capped at 64 KiB during
inspection (or the smaller payload limit plus record overhead). SQLite then uses one streaming payload SELECT over the
validated ordinary table. A length-based conditional projection checks the remaining
byte budget before SQLite selects each BLOB, and a SQLite length limit also bounds intermediate values. Rejected
payload lengths still count as attempted work. Before copying, the selected BLOB's own byte count must match the declared
length. There is no view or sorting step that can buffer payloads ahead of accounting;
the reader buffers only validated typed events.

Database access uses ordinary `SQLITE_OPEN_READONLY`, never `immutable=1` or an unsafe file copy. This does not mutate
database records, but SQLite's normal WAL access may create sidecars and coordinate through SHM read marks.
It is not a guarantee of literal SHM-byte preservation. A platform SQLite build that cannot open a WAL database
without sidecars reports unavailable rather than bypassing normal coordination. Temporary fixture tests compare DB/WAL contents without
writer activity, coordinate subsequent writer activity against one read snapshot, and verify reader cleanup after
cancellation. The fixtures are synthetic and source-linked, not private captures or proof of live installation/UI behavior.

## Constraints
- Internal protocol; fields may change.
- Linux local/CLI port detection requires working `lsof` output or readable process-scoped `/proc` socket metadata;
  macOS uses kernel process-socket enumeration.
- Local HTTPS uses a self-signed cert; the probe allows insecure TLS only for loopback hosts.

## Key files
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityCLISession.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift`
- `Sources/CodexBar/Providers/Antigravity/AntigravityProviderImplementation.swift`
