---
summary: "Codex provider data sources: OpenAI web dashboard, Codex CLI RPC, credits, and local cost usage."
read_when:
  - Debugging Codex usage/credits parsing
  - Updating OpenAI dashboard scraping or cookie import
  - Changing Codex CLI RPC or diagnostic PTY behavior
  - Reviewing local cost usage scanning
---

# Codex provider

Codex has three automatic usage data paths (OAuth API, web dashboard, CLI RPC) plus a manual CLI PTY diagnostic parser and a local cost-usage scanner.
The OAuth API is the default app source when credentials are available; web access is optional for dashboard extras.

## Data sources + fallback order

### App default selection (debug menu disabled)
1) OAuth API (auth.json credentials).
2) CLI RPC through `codex app-server`.
3) If OpenAI web extras are enabled and a matching OpenAI web session is available (Automatic or Manual cookies),
   dashboard extras load as a separate follow-up refresh and the source label becomes `primary + openai-web`.

Usage source picker:
- Preferences → Providers → Codex → Usage source (Auto/OAuth/CLI).

### CLI default selection (`--source auto`)
1) OpenAI web dashboard (when available).
2) Codex CLI RPC through `codex app-server`.

### OAuth API (preferred for the app)
- Reads OAuth tokens from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`).
- CodexBar never publishes refreshed native tokens into `auth.json`; when native credentials are stale,
  the explicit OAuth path delegates recovery to the Codex CLI, which owns that file. If the CLI is unavailable,
  the OAuth error is surfaced instead of mutating the shared file.
- Calls `GET https://chatgpt.com/backend-api/wham/usage` (default) with `Authorization: Bearer <token>`.
- The app reads reset-credit inventory once per refresh with a best-effort
  `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` using the same account-scoped OAuth context;
  the CLI requests it only when optional credits are included.
- The menu and provider settings list every still-available expiry, while the optional credits setting controls
  nearing-expiry notifications. CodexBar does not redeem or modify reset credits.
- `rate_limit.primary_window` / `secondary_window` map to the session/weekly lanes.
- Suspicious weekly resets keep the last trusted usage while confirmation is pending. A successful refresh for the
  same account and workspace clears stale connectivity errors even when the reading is withheld; failed, cancelled,
  or superseded refreshes do not clear them. Cached usage, credits, and other accounts remain unchanged.
- Credits-only updates preserve pending weekly-reset evidence in memory and account-snapshot storage, including
  when published credits are cleared. Candidate admission, expiry, boundary tolerances, and account guards remain
  unchanged; preserving evidence does not make an otherwise incompatible reset eligible for publication.
- Delayed confirmation also accepts an unused weekly window whose reset date advances with observation time:
  both observations must report zero usage, a seven-day duration, and a reset within two minutes of a full week
  ahead. The later reset must not move backward. Exact OAuth, account, plan, unchanged positive reset-credit
  inventory, minimum confirmation age, and candidate expiry checks still apply.
- Debug logs in `codex-weekly-reset-publication` include fixed reason codes for delayed-candidate
  creation, pruning, revalidation, and account-scoped storage requests. They distinguish source/confidence,
  timing, boundary, identity/plan compatibility, and credit-inventory failures without logging account or credit
  identifiers. Codes describe the first rejected prerequisite; they do not relax confirmation policy or prove the
  cause of a past stale reading. `storeRequested` means the file-store call was made, not that a disk write succeeded.
- `additional_rate_limits[]` (model-specific limits such as GPT-5.3-Codex-Spark) map to named
  `UsageSnapshot.extraRateWindows` entries. Spark uses stable `codex-spark` / `codex-spark-weekly` ids and
  `Codex Spark 5-hour` / `Codex Spark Weekly` titles. When the field is absent, the snapshot is unchanged.
- Preferences → Providers → Codex → Visible usage items lets you hide individual Spark rows in menus, the Settings
  preview, and Overview. It does not change fetching, history, notifications, widgets, credits, or other extra limits.

### Optional external OAuth sources (off by default)
- **External Codex OAuth sources** is a provider setting that must be enabled explicitly before CodexBar reads
  another application's OAuth file. It is off by default because this is a cross-application credential boundary.
- Without an explicit `$CODEX_HOME`, native Codex auth wins first, followed by legacy `~/.config/codex/auth.json`,
  then OpenCode's `~/.local/share/opencode/auth.json` (or the equivalent `XDG_DATA_HOME` path).
- An explicit `$CODEX_HOME` remains isolated; it never borrows credentials from those external locations.
- External fallbacks accept OAuth token structures only; API-key entries are ignored. Usage probes never refresh or
  publish OAuth token material into a shared `auth.json` without a cross-writer publication contract. Stale native
  credentials can delegate to the CLI recovery path, while stale external credentials fail closed in every mode.
  Automatic mode also suppresses unscoped CLI fallback whenever a managed workspace is selected. Explicit
  managed-account workspace selection is stored in CodexBar's private managed-account metadata; it never edits the
  source `auth.json` or publishes an `account_id` change back to another application's credential file.
- **Reauthenticate** follows the credential source shown by the account row: System rows use the existing system Codex login flow even when the same account is also saved; managed rows renew their private managed home. Credentials are not copied between those homes. A queued action is discarded if the row's source or workspace changes.
- If native credentials need renewal, use **Reauthenticate** for the affected account in Settings → Providers → Codex.
  For CLI recovery, run `codex login` with that account's existing `CODEX_HOME` and select the intended workspace.
  The refresh error describes this manual recovery without promising automatic CLI fallback for managed workspaces.
- Stacked account refreshes retain each managed account's selected workspace through usage publication and menu
  matching, even when its auth file names a different default workspace. Changing the selected workspace while a
  refresh is running discards the old workspace's result.
- System Account promotion fails closed when a managed selection differs from the auth file's default workspace.
  CodexBar keeps that selection managed rather than silently promoting the default or rewriting Codex-owned auth.
- After a successful System Account promotion, CodexBar restarts an already-running managed `codex app-server`
  daemon for the destination Codex home so it reloads the selected account. It checks the daemon PID, process command,
  and home-scoped control socket before running `codex app-server daemon restart` with that home's `CODEX_HOME`.
  Homes without a running daemon are left alone. If the installed CLI cannot verify or restart it (including older
  CLIs without daemon commands), the account remains switched and the menu/settings show a manual-restart note.
  Restarting the background server can interrupt its active work; no login flow runs.
- In the segmented layout, selecting an account refreshes its card while the menu stays open. Delayed results stay
  scoped to that selection. An open chart submenu or highlighted menu command can defer the update until the submenu
  closes or the highlight clears.
- Reusing OpenCode OAuth enables remote account quota, not OpenCode session token/cost ingestion. See
  [OpenCode with Codex or OpenAI](opencode.md#using-opencode-with-codex-or-openai) for the current history boundary.

### Advanced profile-home accounts
- Managed Codex accounts remain the default multi-account path.
- Advanced users can add existing Codex homes to `~/.codexbar/config.json` with
  `providers[].codexProfileHomePaths`.
- Each configured path must be absolute or start with `~/`, and point at a Codex home that contains `auth.json`.
- CodexBar reads identity from the configured home, exposes it in the Codex account switcher, and scopes
  remote Codex fetches with `CODEX_HOME`.
- Profile homes are not copied, reauthenticated, or removed by CodexBar.
- Selecting a profile-home usage card does not promote credentials or restart its daemon. Daemon refresh belongs to
  System Account promotion and targets only the home whose auth file was replaced.

Example:

```json
{
  "id": "codex",
  "codexProfileHomePaths": [
    "~/.codex-work",
    "~/.codex-personal"
  ]
}
```

### Same-email workspace labels

Account settings, the System Account picker, and the menu switcher retain the workspace name when it is available.
If the same email and workspace label would appear more than once (including missing names or the “Personal” fallback),
CodexBar adds a stable eight-character hash of the workspace identity. The hash stays the same when selecting or promoting
that workspace and never exposes the full provider identifier. This is display-only; stored account metadata and
credential selection are unchanged. Separate profile homes for the same workspace also include a hashed source identity,
so their labels stay distinct without exposing paths. Compact switcher buttons keep the discriminator visible when space
is limited, using additional rows when needed.
Hide Personal Info applies to the System Account submenu as well as the switcher: email addresses are removed,
and stable account numbers distinguish rows while usable workspace labels remain visible.

### OpenAI web dashboard (optional, off by default)
- Subscription renewal or expiration dates load after the app publishes dashboard usage. CodexBar first tries the subscription API, then captures only the date and renewal flag from ChatGPT's own billing request in the same account-scoped web session, within an eight-second budget.
- Billing capture is best-effort: unavailable or malformed responses retain previously fetched dates, while a valid empty response clears them. Cancelled, replaced, disabled, or account-mismatched refreshes cannot attach dates. The CLI web source waits only within its remaining fetch deadline.
- Enable it in Preferences -> Providers -> Codex -> OpenAI web extras.
- It exists for dashboard-only extras such as code review remaining, usage breakdown, and credits history.
- It is intentionally opt-in because it loads `chatgpt.com` in a hidden WebView and can materially increase battery or network usage.
- OpenAI web battery saver is a separate toggle. When enabled, routine background/settings-driven refreshes are reduced, but explicit manual refreshes still run.
- OpenAI web battery saver currently defaults to off.
- Preferences → Providers → Codex → OpenAI cookies (Automatic or Manual).
- URL: `https://chatgpt.com/codex/settings/usage`.
- Uses an off-screen `WKWebView` with a per-account `WKWebsiteDataStore`.
  - Store key: deterministic UUID from the normalized email.
- WebKit store can hold multiple accounts concurrently.
- Each WebView acquisition keeps ownership across asynchronous page preparation. Explicit store eviction invalidates
  that store's pending preparations, so stale success, failure, or timeout retry cannot displace a replacement view.
  Evict-all invalidates all pending preparations; ordinary lease release does not invalidate concurrent temporary views.
- Leases retain their cleanup owner independently of the cache and release only once. Validated pages still support
  the brief reuse handoff; other releases schedule the existing deferred WebKit cleanup, including temporary views.
- Cookie import (Automatic mode, when WebKit store has no matching session or login required):
  1) Safari: `~/Library/Cookies/Cookies.binarycookies`
  2) Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
  3) Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`
  - Domains loaded: `chatgpt.com`, `openai.com`.
  - No cookie-name filter; we import all matching domain cookies.
- Cached cookies: Keychain cache `com.steipete.codexbar.cache` (account `cookie.codex`, source + timestamp).
  Reused before re-importing from browsers.
- Manual cookie header:
  - Paste the `Cookie:` header from a `chatgpt.com` request in Preferences → Providers → Codex.
  - Used when OpenAI cookies are set to Manual.
- Account match:
  - Signed-in email extracted from `client-bootstrap` JSON in HTML (or `__NEXT_DATA__`).
  - If Codex email is known and does not match, the web path is rejected.
- Web scrape payload (via `OpenAIDashboardScrapeScript` + `OpenAIDashboardParser`):
  - Rate limits (5h + weekly) parsed from body text.
  - Credits remaining parsed from body text.
  - Code review remaining (%).
  - Usage breakdown chart (Recharts bar data + legend colors).
  - Credits usage history table rows.
  - Credits purchase URL (best-effort).
- Errors surfaced:
  - Login required or Cloudflare interstitial.

### Codex CLI RPC (automatic CLI source)
- Launches local RPC server: `codex -s read-only -a never app-server`.
- JSON-RPC over stdin/stdout:
  - `initialize` (client name/version)
  - `account/read`
  - `account/rateLimits/read`
- RPC reads are bounded: initialization has a longer startup budget, and normal requests have a shorter per-method
  timeout. On timeout, CodexBar closes the child `codex app-server` process's stdin and escalates from SIGTERM to
  SIGKILL after a bounded grace period, so the stdout reader unwinds and unresponsive children cannot linger.
- Provides:
  - Usage windows (primary + secondary) with reset timestamps.
  - Credits snapshot (balance, hasCredits, unlimited).
  - Account identity (email + plan type) when available.
- The plan from the fresh rate-limit response takes precedence over the account's cached plan after a subscription
  change. A missing or blank rate-limit plan falls back to the account response; email still comes from that account.
- App-server errors are terminal for the CLI strategy, except when Codex includes a recoverable `wham/usage` JSON body in the error text.
- If macOS blocks or quarantines the `codex` executable, CodexBar records the launch failure and skips background CLI
  launches for 30 minutes. Use a manual refresh after reinstalling or unblocking `codex` to retry immediately.
- CodexBar also discovers the Codex CLI bundled with current ChatGPT and legacy Codex desktop apps, even when `codex`
  is absent from the shell PATH.
- If managed Codex account login still reports a missing executable, turn on **Show debug settings** in
  **Settings > Advanced**, then check **Settings > Debug > CLI Paths**. When no Codex binary appears there, confirm
  `codex --version` works in Terminal, check `which -a codex` for stale duplicate installs, then run
  `npm install -g --include=optional @openai/codex@latest` before retrying Add Account.

### Codex CLI PTY diagnostics (`/status`)
- Manual/debug parser only; automatic background refresh and `CodexBarCLI usage --source cli` do not launch bare Codex TUI.
- Kept for explicit diagnostics/parser coverage because bare `codex` TUI can start interactive auth and open browser tabs.
- Parses rendered `/status` output:
  - `Credits:` line
  - `5h limit` line → percent + reset text
  - `Weekly limit` line → percent + reset text
- Detects update prompts and surfaces a "CLI update needed" error.

## Account identity resolution (for web matching)
1) Latest Codex usage snapshot (from RPC, if available).
2) `~/.codex/auth.json` (JWT claims: email + plan).
3) OpenAI dashboard signed-in email (cached).
4) Last imported browser cookie email (cached).

## Credits
- Background credits refreshes coalesce for the same account. Cancelling and replacing a refresh keeps the replacement tracked until it finishes; retired credits and history-backfill tasks cannot clear newer work.
- Web dashboard fills credits only when OAuth/CLI do not provide them. Account-matched extra usage reconciles monthly caps and purchased balances separately; the optional credits setting controls visibility.
- When usage reports limited workspace credits without an amount, an optional read of the account's `remaining_balance` endpoint uses the same OAuth or browser session. Access depends on workspace permissions. Failure preserves ordinary usage and monthly-limit data.
- Workspace balances attach and persist only when the dashboard response account ID matches the selected account. Same-email workspace mismatches and old workspace caches without an account ID are rejected by both the app and CLI.
- A newer explicitly unavailable workspace balance suppresses an older cached amount, including after restart. A later successful positive or zero balance restores visibility. Usage-only refreshes that skip the balance read preserve the account's prior observation; account changes never inherit it.
- The custom **Balance** menu-bar token supports Codex credits, rounded and grouped as whole credits. Workspace pools remain distinct from a member's monthly cap and do not imply a total pool capacity.
- Personal credit bars without a reported monthly cap use the next power of ten above the balance as their visual scale (for example, 1,250 credits on a 10K scale). This scale is not an inferred allowance; reported monthly caps keep their exact scale, and workspace pools remain amount-only.
- CLI RPC: `account/rateLimits/read` → credits balance.
- CLI PTY diagnostics can still parse `Credits:` from saved/manual `/status` output.

## Cost usage (local log scan)

Usage & Spend includes this Mac's Codex session home even when the CLI keeps credentials in the OS keyring and
there is no `auth.json`. Local cost estimates do not require account identity or a successful quota refresh.
Managed and profile homes retain their separate history scopes; a home already represented by a visible account
is not added again as a local source. This does not read the CLI's keyring credentials.

For a manual comparison with another development machine, run `codexbar cost --provider codex --remote <ssh-host>`.
Both hosts scan their own native Codex logs once and return separate summaries, retaining their own day boundaries,
pricing provenance, missing values, and incomplete-request counts. Only bounded totals cross SSH. A remote error keeps
the local result and returns a nonzero exit code. See [CLI host reporting](cli.md) for the versioned summary contract.

In the app, choose **SSH Cost Report…** from the Codex menu, enter an existing SSH alias or `user@host`, and click
**Refresh**. The host must already support noninteractive SSH with a trusted host key and a CodexBar CLI supporting
native `--daily-summary` reports. The window shows Today and the last 30 days for each machine, plus separate daily
charts with a Token/Cost switch and hover details. Both machines bucket the 30-day history in the app's cost-history
timezone. Each report retains its original source snapshot timestamp, explicit timezone, and incomplete-history or
pricing warnings. Unknown values are not plotted as zero. Amounts are USD API-equivalent estimates, not bills.
This Mac means ambient native Codex history, independently of the selected managed account and without Pi/OMP sessions.
Opening the window does not scan or connect. A failed source leaves the other source's successful report visible.
Cancel or close the window to cancel the query; the host field remains locked until the query drains.
The host is remembered only while the app is running and is masked by **Hide Personal Info**.
These reports do not add histories together or change ordinary menu totals, charts, or refresh behavior.

The app requests a bounded numerical daily report using
`codexbar cost --provider codex --format json --daily-summary --provider-native-only --days 30 --bucket-time-zone <zone>`.
Only daily token/cost amounts, coverage, incomplete-request counts, provenance, and timestamps cross SSH; model,
project, session, account, and path details are excluded. Older CLIs must be updated for this daily protocol;
the existing CLI `--remote` / `--summary-only` totals contract is unchanged.

- Menu source selection:
  - By default, a selected managed account keeps its own `CODEX_HOME` session history.
  - **Local session cost estimates** is a Codex-only opt-in that instead scans this Mac's ambient `$CODEX_HOME`
    (or `~/.codex`) independently of quota, OAuth, web-dashboard, and administrator access.
  - Multi-account menus show an ambient ledger once under **This Mac**, honoring inline, submenu, or combined display.
    Managed-account and profile-home history is never promoted to this shared section.
  - Regular menu cost refreshes publish local session estimates even when global cost tracking is off. This does not
    enable other providers' cost scans; results still require the same provider configuration and history/account scope.
  - The local-only mode never makes a network request or uploads session content. It uses an existing local models.dev
    cache when available, then the bundled `CostUsagePricing` rates.
- Source files:
  - Native Codex logs:
    - `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
    - `~/.codex/archived_sessions/*.jsonl` (flat; date inferred from filename when present)
    - Or `$CODEX_HOME/sessions/...` + `$CODEX_HOME/archived_sessions/...` if `CODEX_HOME` is set.
  - Supported pi-compatible sessions:
    - `~/.pi/agent/sessions/**/*.jsonl`
    - `~/.omp/agent/sessions/**/*.jsonl`
- Scanner:
  - Codex reserve telemetry uses the bundled GPT-5.6 Luna list-price estimate, including existing cached token rows.
    This estimates API-equivalent cost; it is not a charge for using a subscription reserve allowance.
  - Bundled `gpt-6-astra` pricing covers input, cache reads/writes, output, and the full-request long-context
    threshold above 272K input tokens. Astra Fast pricing is twice the applicable Standard rates when
    existing priority-request evidence selects that mode. Stored token rows are repriced without a history rebuild.
    Rates follow the [OpenAI model card](https://developers.openai.com/api/docs/models/gpt-6-astra) and
    [pricing table](https://developers.openai.com/api/docs/pricing).
  - Valid JSON whitespace between event fields is accepted during initial scans and appended-session refreshes.
    Older cached files are reparsed once through the normal scan budget; compatible stores retain their rows and
    checkpoints until each file is refreshed.
  - Native Codex logs parse `event_msg` token_count entries and `turn_context` model markers; when both are present,
    `turn_context` is authoritative for the model bucket.
  - Direct forks preserve the inherited origin of cumulative counters when resolving parent snapshots, including
    intermediate sessions that are empty at the child's fork time. Repeated inherited snapshots contribute no
    new usage; descendants count only their deltas. Ancestry remains a cache dependency, so ancestor changes
    revalidate descendants even if the intermediate session records its first token event after the fork.
    Parser revision 5 repairs existing files through bounded reparsing without discarding compatible stored history.
  - A subagent's `subagent_history_start_ordinal` is authoritative: earlier records are inherited context, even if
    they contain delivery markers or the file ends before child-owned history arrives. Later appends count only
    the child's own deltas. Older per-file parser revisions refresh through the normal scan budget while stored
    history and checkpoints remain available.
  - Compact forks with an opening cumulative snapshot and zero input/cached/output `last_token_usage`
    components treat that snapshot as inherited, even when the parent file is unavailable. At the first owned
    event, component-wise `total_token_usage - last_token_usage` establishes the baseline when available;
    it need not exactly match an earlier inherited snapshot. Later cumulative deltas retain replay deduplication.
    Unchanged snapshots remain inherited. A nondecreasing snapshot whose `last` repeats the cumulative
    usage is also inherited when a nonzero baseline is known; equality alone cannot establish a reset.
    Zero baselines and counter decreases preserve fresh child counters. The aggregate `total_tokens`
    field does not override the component counters.
  - Paginated continuation files count only their own suffix when `history_base.thread_id` identifies a previous
    page rather than the original fork ancestor. Bounded scans retain the resolved fork baseline across restarts
    and revalidate its parent before resuming. Cross-file request identity includes the timestamp so restarted
    page-local event indices do not erase distinct requests; exact active/archive copies still deduplicate.
  - pi and OMP sessions count assistant-message usage rows and attribute `openai-codex` assistant usage to Codex.
  - pi-compatible assistant usage is bucketed by assistant-turn timestamp, so mixed-model sessions can contribute to
    multiple days/models correctly.
  - Matching assistant entry IDs within the same session are counted once across roots; distinct turns are retained.
  - Native conversation rows reuse the corrected cached per-file totals and existing pricing tables. They are hidden
    when pi-compatible usage joins the aggregate because the native-only rows would not reconcile with the merged total.
- Cache:
  - Native session store: `~/Library/Caches/CodexBar/cost-usage/cost-usage.sqlite`
  - pi-compatible session cache: `~/Library/Caches/CodexBar/cost-usage/pi-sessions-v9.json`
    is replaced atomically on macOS and Linux, retaining complete cached scan state across refreshes.
    Version 8 rebuilds once from transcripts to establish source scope and completeness. Enabling the standalone
    [Pi provider](pi.md) keeps Codex history native-only in combined views and completed catch-up publication.
  - Catch-up status reads progress metadata without loading historical usage JSON or replay bodies. Cached token
    activity reads scoped daily aggregates without decoding individual usage events, retaining account, time zone,
    coverage, and incomplete-scan checks. Cached reports
    retain row-level pricing evidence and project/session details, but omit raw token snapshots, accumulator state,
    and replay bodies. File cursor metadata, including JSONL resume state, remains available for progress tracking.
    Fresh and cached fetches use progress metadata to recognize retained reports during catch-up, skipping
    detail-row decoding that would be discarded. Reports without a matching retained result still load exact details.
    During historical catch-up, a validated reporting window can publish once its discovery, parser, materialization,
    and fork-ownership checks are complete. Metadata-only reads do not establish day coverage; unresolved or unparsed
    work retains the previous report. Cached publication is attempted before duty-cycle and resource-pause sleeps and
    after bounded passes, preserving power limits and actual cache timestamps rather than stamping publication as a new scan.
    A native scan loads exact usage rows once, deferring raw token history and checkpoints until a file changes
    or a fork needs its ancestors. A single-use receipt binds those deferred reads and saves to the original
    connection, database identity and SQLite change observations,
    checking again under the writer lock. Filesystem/anchor and catch-up reconciliation still run at comparison
    time; a concurrent database change requests a rescan. Fresh database opens retain integrity validation.
  - Scan loads also retain decoded baselines for up to four recently used cache roots while the database stamp is unchanged. Each load issues a fresh save receipt and rechecks transcript identity; writes, failed operations, schema changes, and database replacement invalidate reuse.
  - Up to four recently used cache roots retain validated reader connections and decoded status/activity data.
    External writes invalidate cached data; database replacement or incompatible metadata reopens the reader through
    existing validation on its next access. Every read still reconciles file identities, and detailed report history
    remains transient. Scanner and writer connections keep separate ownership.
  - Workspaces cache reads decode stored usage rows as SQLite yields them, avoiding a second retained copy of the
    history as encoded payloads. Metadata and rows share one read transaction; filesystem reconciliation runs after
    it closes. Row order, pricing, malformed-row fallback, and incomplete coverage keep their existing behavior.
  - Saved day/model aggregates group each file's usage rows in one pass per aggregate build. Packed token totals,
    authoritative costs (including zero), and standard/priority estimation buckets retain their existing meanings.
  - Saves skip unchanged files using the transaction-validated scan baseline, so a changed session or scan metadata
    does not rewrite every retained file's metadata, aggregates, fork state, buffers, and accumulator. Changed files,
    parser/calendar migrations, and incomplete persisted row sets still take the normal persistence path.
  - Excess cached request rows trigger bounded revalidation of readable, unchanged session files. Ordered source
    replay determines the request sequence; matching token totals alone cannot establish a request partition.
    Unanimous saved pricing survives partial scans and restarts. Files with authoritative monetary amounts, existing
    unpriced markers, or conflicting saved pricing retain their rows without automatic rewriting. Recovered requests
    without matching historical pricing remain unpriced. The repair retains the existing database and scan checkpoints.
    Resumes retain the original target anchor alongside the parsed-prefix anchor and follow the scanner's existing
    append-only log contract; identity changes, anchor mismatches, and unexplained same-size large-file edits invalidate pricing.
    Parser-revision upgrades use the same source validation to preserve matching historical prices when a file
    grows or a recovery scan is interrupted. Appended requests cannot borrow prices from the historical prefix,
    and an invalidated pricing map remains invalid through subsequent upgrades. Native stores from 0.62.0's
    `865a444e01b818f1` fingerprint retain their history while individual files are reparsed with corrected accounting.
  - Fully read empty session fragments retain completion records even when another file contributes the same session.
    They contribute no usage and reparse from the start if they grow. Usage-bearing duplicates and incomplete fragments
    keep their existing accounting and retry rules. Existing 0.56.4 cost caches are adopted without rebuilding
    stored usage, retained reports, or partial-scan checkpoints.
  - On macOS and Linux, local Priority/Fast pricing evidence is read from the host's Codex SQLite trace database.
    Priority trace scans resume after ordinary log pruning when enough distributed content anchors still match;
    changed source rows, replaced databases, or insufficient matching anchors require a fresh scan. Temporary
    trace-database failures retain the last validated report pricing and leave scan freshness unchanged for retry.
    Successful historical queries update their own pricing window independently of the live scan cursor, including
    results with no priority turns; validated pricing outside that window remains intact.
- Window: configurable 1-365 day rolling history.
- Pending cost scans retain their discovery range when the same cache receives narrower or wider history requests ending on the same day. Reports still use the requested dates, and compatible existing caches retain stored usage and partial-scan progress on upgrade. A new ending day, changed roots/timezone, or a forced rescan keeps the usual discovery reset behavior.
- Routine rescans of changed sessions replace request-pricing rows within the scan window alongside token totals. Cached rows outside that window remain available; obsolete rows cannot make an otherwise priceable day lose its cost estimate. Budget-limited scans retain matching request-pricing evidence and the parser position across restarts, without counting unparsed requests in active totals. Upgrades from 0.60.1 retain saved history, including sessions whose source files are no longer available.
- App cadence: regular timer-driven local-history refreshes have a 15-minute minimum (30 minutes in Low Power Mode).
  Manual disables the recurring refresh timer, not all scan activity: startup refreshes and pending Codex catch-up can
  still scan local history. Faster provider refreshes still update quota/status. The scanner's default 60-second
  debounce is a separate internal limit, bypassed by forced scans and catch-up passes; it is not the app's refresh cadence.
- Usage & Spend catch-up remains inactive after a no-progress or error pause until you choose **Refresh** in the dashboard toolbar or catch-up panel. Opening the dashboard or receiving background updates does not retry those terminal pauses. Low-power and thermal pauses can still recover automatically; this retry policy does not change cached history or token accounting.
- Menu cost catch-up discards an overlapping refresh queued before a no-progress or error pause, preventing an immediate retry. A later normal or manual refresh can still start a fresh attempt; successful completion still honors queued refreshes for newly discovered history.
- Automatic Codex catch-up scheduling in both usage and Spend Dashboard honors the app’s 30-minute Low Power Mode minimum after each pass. Explicit acceleration remains immediate, and physical low-power/thermal pauses retain their own retry policy. The setting applies when the next delay is computed; an already pending sleep is not replanned.
- Automatic catch-up reports thermal pressure when serious heat and Low Power Mode coexist. Both constraints keep the existing 60-second pause before rechecking resource state.
- A catch-up worker that loses its account or settings scope clears its abandoned Refreshing activity on exit. Legitimate pauses remain visible, and an older worker cannot clear a replacement worker's activity.
- Cache-wide migration reseeding keeps paths already waiting ahead of new revisits. Repeated pricing or priority-turn changes therefore cannot keep the same completed files ahead of the stale tail in each 512-candidate pass. Initial seeding still honors newest-first preference, and publication waits for exact inventory validation. Native Codex stores from published parser fingerprint `4969a789db679c93` adopt the new generation without rebuilding rows, checkpoints, or retained reports; Pi/OMP retains its existing one-time reparse on a parser-hash change.
- When a warm cost refresh reaches its time limit, it saves the remaining file work and completed discovery. Compatible shorter/wider history requests resume that work across the retained scan range; publication still waits for exact inventory validation.
- Quota-week menu cards reuse the immutable snapshot’s day projection, warmed in the background. New snapshots and changed bucket time zones rebuild it; reset observations and the current time remain live on every card build.
- Inline cost charts preserve a slot for every day in that window, using the selected cost-bucket time zone and the snapshot's date. Missing days are zero only after history coverage is established; unscanned days and entries without prices remain unknown. Long windows fit within the menu width without dropping dates.
- **Hide personal information** also replaces account-switcher emails with numbered labels and sanitizes email addresses embedded in workspace hints. Narrow switchers retain the account number, and tooltips use the same labels without emails.
- **Hide personal information** replaces project/source names with numbered labels and hides their paths in the cost-history submenu; Usage & Spend also masks project names. Costs, tokens, grouping, and stored history are unchanged, and disabling the setting restores the original labels. This is display masking, not data deletion or export sanitization.
- While a bounded refresh catches up with new session history, established totals remain visible only for the same
  account, history window, and bucket time zone. An incomplete first scan never borrows another account's totals.
- Pending local-history files receive a turn before fresh work, within the existing byte and duration limits.
  Unfinished files rotate behind waiting work, and the queue survives restarts without rebuilding compatible caches.
- Parent-session discovery also resumes within those limits after the requesting fork files leave both scan roots.
  Stale pending path associations are reconciled in the existing cache; surviving forks with missing parents still
  retain their unresolved usage instead of being counted as complete.

### Usage & Spend account rows

Settings → Usage & Spend performs a separate fixed 30-day scan for every visible Codex account. Each request freezes
the account source, exact Codex home, authentication fingerprint, and cache identity before scanning. A missing or
invalid home is omitted; it never falls back to ambient `~/.codex` or to the global Codex token snapshot.

These account rows intentionally exclude pi and OMP sessions because their history is machine-local rather than owned
by one Codex account. The normal Codex cost menu and CLI scan continue to include supported pi-compatible history. The
dashboard labels its values as local estimates and keeps currencies separate.

## Key files
- Web: `Sources/CodexBarCore/OpenAIWeb/*`
- CLI RPC + diagnostic PTY parser: `Sources/CodexBarCore/UsageFetcher.swift`,
  `Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift`
- Cost usage: `Sources/CodexBarCore/CostUsageFetcher.swift`,
  `Sources/CodexBarCore/PiSessionCostScanner.swift`,
  `Sources/CodexBarCore/PiSessionCostCache.swift`,
  `Sources/CodexBarCore/Vendored/CostUsage/*`

Automatic local-history catch-up bases its duty-cycle delay on time spent executing its own scan, including cache
publication. Time waiting behind another account or provider on the shared scan queue does not increase that delay.
The existing power, thermal, scan-budget, and complete-history publication rules still apply.
