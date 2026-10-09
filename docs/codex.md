---
summary: "Codex provider data sources: OpenAI web dashboard, Codex CLI RPC, credits, and local cost usage."
read_when:
  - Debugging Codex usage/credits parsing
  - Updating OpenAI dashboard scraping or cookie import
  - Changing Codex CLI RPC or diagnostic PTY behavior
  - Reviewing local cost usage scanning
---

# Codex provider

The **Plan Usage** submenu includes recorded remaining-quota burndown above utilization history,
including saved Monthly windows. See [recorded quota burndown](widgets/burndown-proof.md)
for capture-age semantics and the existing history retention/privacy behavior.

Codex reads account usage through PAT, OAuth, CLI RPC, or an explicitly selected web dashboard source.
Local token/cost history is scanned separately; the CLI PTY parser is a manual diagnostic tool.

## Data sources + fallback order

### Auto selection (app and CLI `--source auto`)
1) PAT, when available.
2) OAuth API (auth.json credentials).
3) CLI RPC through `codex app-server`, unless a managed workspace is selected.

Unavailable strategies are skipped. Authentication failures can allow fallback; network, server, and decode
failures keep their original error. Stale external OAuth credentials fail closed. A managed workspace disables
CLI fallback because the CLI cannot receive CodexBar's selected workspace header.

If OpenAI web extras are enabled in the app and a matching OpenAI web session is available (Automatic or Manual
cookies), dashboard extras load as a separate follow-up refresh and the source label becomes `primary + openai-web`.
The web dashboard is not an Auto fallback; the CLI can select it explicitly with `--source web`.

Usage source picker:
- Preferences → Providers → Codex → Usage source (Auto/OAuth/CLI).

### OAuth API (preferred for the app)
- Reads OAuth tokens from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`).
- OAuth availability and usage reads retry a missing, unreadable, or partially published credential file twice,
  50 milliseconds apart. Usage also rereads a native token due for renewal before reporting that it needs refresh.
  A successful retry retains the selected workspace; unchanged stale credentials still require their owner's renewal.
- CodexBar never publishes refreshed native tokens into `auth.json`; when native credentials are stale,
  the explicit OAuth path delegates recovery to the Codex CLI, which owns that file. If the CLI is unavailable,
  the OAuth error is surfaced instead of mutating the shared file.
- Calls `GET https://chatgpt.com/backend-api/wham/usage` (default) with `Authorization: Bearer <token>`.
- A `chatgpt_base_url` setting in `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`) overrides the usage endpoint. Lines beginning with `#`, including indented comments, are ignored; a commented override cannot shadow an active setting later in the file. Trailing inline comments remain supported.
- The app reads reset-credit inventory once per refresh with a best-effort
  `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` using the same account-scoped OAuth context;
  the CLI requests it only when optional credits are included.
- The menu and provider settings list every still-available expiry, while the optional credits setting controls
  nearing-expiry notifications. CodexBar does not redeem or modify reset credits.
- `rate_limit.primary_window` / `secondary_window` map to the session/weekly lanes.
- Suspicious weekly resets keep the last trusted usage while confirmation is pending. A successful refresh for the
  same account and workspace clears stale connectivity errors even when the reading is withheld; failed, cancelled,
  or superseded refreshes do not clear them. Cached usage, credits, and other accounts remain unchanged.
- A fresh exact OAuth result with a changed, known plan starts a new quota baseline for that account. Previous-plan
  reset backfill and pending reset candidates cannot hold the old plan on screen. A first near-zero weekly reading
  still requires confirmation from the same plan; missing or unchanged plans retain the normal reset safeguards.
- Credits-only updates preserve pending weekly-reset evidence in memory and account-snapshot storage, including
  when published credits are cleared. Candidate admission, expiry, boundary tolerances, and account guards remain
  unchanged; preserving evidence does not make an otherwise incompatible reset eligible for publication.
- Missing historical reset-credit inventory does not hold back a confirmed advanced weekly reset: two fresh exact
  readings with matching positive credit inventories and compatible account and plan can publish the fresh quota,
  credits, and update time. Both credit observations must be newer than the last trusted usage; missing, stale, or
  inconsistent fresh inventories still withhold the reset. A known historical inventory retains its consumption
  checks; an unchanged reset boundary still requires delayed confirmation.
- Delayed confirmation also accepts an unused weekly window whose reset date advances with observation time:
  both observations must report zero usage, a seven-day duration, and a reset within two minutes of a full week
  ahead. The later reset must not move backward. Exact OAuth, account, plan, unchanged positive reset-credit
  inventory across fresh observations (and historical inventory when present), minimum confirmation age, and
  candidate expiry checks still apply.
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
- Enable **External Codex OAuth sources** to allow reads of another application's OAuth file. This cross-application credential access defaults off.
- Without `$CODEX_HOME`, precedence is native Codex auth → legacy `~/.config/codex/auth.json` → OpenCode's `~/.local/share/opencode/auth.json` (or equivalent `XDG_DATA_HOME`). An explicit `$CODEX_HOME` stays isolated.
- External sources accept OAuth tokens only, ignoring API-key entries. Usage probes cannot refresh or publish tokens to shared `auth.json` without a cross-writer publication contract. Stale native credentials may delegate to CLI recovery; stale external credentials fail closed in every mode. Managed workspace selection suppresses unscoped Auto CLI fallback and stays in private CodexBar metadata, never rewriting source `auth.json` or `account_id`.
- **Reauthenticate** follows the credential source shown by the account row: System rows use the existing system Codex login flow even when the same account is also saved; managed rows renew their private managed home. Credentials are not copied between those homes. A queued action is discarded if the row's source or workspace changes.
- If native credentials need renewal, use **Reauthenticate** for the affected account in Settings → Providers → Codex.
  For CLI recovery, run `codex login` with that account's existing `CODEX_HOME` and select the intended workspace.
  The refresh error describes this manual recovery without promising automatic CLI fallback for managed workspaces.
- Stacked account refreshes retain each managed account's selected workspace through usage publication and menu
  matching, even when its auth file names a different default workspace. Changing the selected workspace while a
  refresh is running discards the old workspace's result.
- System Account promotion fails closed when a managed selection differs from the auth file's default workspace.
  CodexBar keeps that selection managed rather than silently promoting the default or rewriting Codex-owned auth.
- System Account promotion restarts an already-running managed daemon with `codex app-server daemon restart` and the destination home's `CODEX_HOME`. It verifies PID, process command, and resolved home-scoped control socket, including symlinked homes and sockets in Codex's protected directory outside the home. Dangling links still require the CLI's running-daemon probe. Homes without a running daemon are untouched. If verification/restart is unsupported or fails, the account remains switched with a manual-restart note in menu/settings. Restart can interrupt active server work; it runs no login flow.
- In the segmented layout, selecting an account refreshes its card while the menu stays open. Delayed results stay
  scoped to that selection. An open chart submenu or highlighted menu command can defer the update until the submenu
  closes or the highlight clears.
- Saved account readings are independent of account-widget visibility. Refreshing a selected account preserves
  valid sibling readings, their original ages, errors, and credits in memory and across restart. Removed accounts
  and rows whose ownership no longer matches the current account list are pruned; refresh failures only invalidate
  the affected account's reading.
- Settings → Providers → Codex shows each visible account's saved usage when multiple OAuth accounts are available.
  Opening the pane reads the retained snapshots without starting a refresh. Each row keeps its own usage age and
  error, including accounts not fetched yet, and distinguishes **CodexBar follows** from **System**.
  The first failed refresh after managed credentials rotate shows its authentication error. Another rotation
  discards the previous credentials' error, even when the saved account metadata has not changed.
  **Hide personal information** uses the same numbered account and workspace labels as the account switcher.
  Authorized OpenAI Code review usage remains on the followed account's row; sibling rows never inherit it,
  and same-email ambiguity keeps the existing display-only dashboard policy.
- Refresh an individual row or choose **Refresh all accounts** to visit every account in batches of up to six,
  without changing the followed account or promoting credentials to System. The provider header keeps its existing
  account-scoped refresh, including credits and OpenAI web extras. Zero or one account, and ambient PAT mode, keep
  the single-account presentation. Local token/cost usage appears once, with its current-profile or **This Mac** scope.
- Reusing OpenCode OAuth enables remote account quota, not OpenCode session token/cost ingestion. See
  [OpenCode with Codex or OpenAI](opencode.md#using-opencode-with-codex-or-openai) for the current history boundary.

### “Codex auth.json needs refresh”

This message comes from the local credential freshness check, before the usage HTTP request. Native credentials
with a recognized token expiry need renewal within five minutes of expiry; otherwise CodexBar uses the saved
`last_refresh` timestamp and an eight-day threshold. File modification time is not the freshness signal. Network,
HTTP, and decoding errors have separate messages.

CodexBar rereads credentials briefly in case their owner is replacing them. A later owner-CLI renewal can therefore
restore OAuth usage without another login. A managed workspace still requires renewal in its own Codex home;
successful web usage or a healthy custom proxy does not establish that credential's freshness or workspace identity.
If the warning recurs, record the usage source, system/managed/profile selection, source label, and timestamps on
both the failing and successful refresh. Do not share tokens or the contents of `auth.json`.

### Managed account CLI (macOS)

Use `codexbar codex-accounts list --json` to find managed UUIDs and the current system-identity match,
then `codexbar codex-accounts promote <exact-uuid-or-email>` to promote an account explicitly. Duplicate
emails require the UUID. The app and CLI share the same preservation and workspace checks: displaced
live credentials are saved before an owner-only atomic replacement, and detected changes to either
auth file abort the replacement. A nonblocking process lock serializes participating account writers
and is released automatically after a crash. External Codex processes do not share that lock.
Preservation checks every selectable repair destination—provider-keyed or legacy email-only—and
rechecks saved authentication before replacing or deleting a managed destination. Read failures or
conflicting credentials abort the promotion.
Refreshed copies are read back before their fingerprints are committed, and every preserved copy is checked
again immediately before the live replacement. External writers can still race after the final read.

Saved-account removal and import repair retain an old managed home while another saved record references
the same path. Cleanup still requires the managed-home safety checks and releases the home after its last reference.

CLI promotion reads local files only and never requests Keychain access or starts login. It leaves
the app's display selection and running Codex processes alone; `CODEX_HOME` selects the live destination.
That destination must not alias a managed home, because the swap would overwrite its preserved credentials.
It does not renew expired credentials or enable unscoped fallback for managed workspaces. Continue to
use the affected row's **Reauthenticate** action or ordinary `codex login` scoped to that managed home
and intended workspace. A future CLI renewal command needs staged login and identity/workspace
validation before committing; `promote` is not a renewal workaround. See [CLI details](cli.md#managed-codex-accounts-macos).

### In-process managed credential resolution

`ManagedCodexAccountCredentialResolver` resolves an explicit managed-account UUID using a metadata-only store
and a trusted managed-home root. It reads the selected native OAuth file, checks its owner and native default
workspace against the saved account, and revalidates the registry binding and original home before returning
an access-only credential. Organization membership alone does not establish the native default workspace.
Promotion retains its existing email precedence; credential release requires unambiguous owner claims.

The fresh-only policy requires a known expiry beyond the larger caller or authority minimum plus clock skew.
Defaults are a 60-second authority minimum and 30 seconds of skew; minimum-validity requests above one day
are unsupported. Missing expiry requires renewal rather than relying on file dates or `last_refresh`.
The result exposes the bearer through `withAccessToken` and includes `expiresAt`; diagnostics are redacted.
Typed failures distinguish renewal, temporary unavailability, missing accounts, and unsupported requests.

This is a core API with no CLI, HTTP, or IPC credential-export endpoint. It does not choose an active account,
fall back to another account, start login, refresh credentials, cache tokens, or write credentials or registry data.
Validation checks local consistency rather than JWT signatures or upstream acceptance. Filesystem revalidation
is observational, not an atomic transaction against hostile same-user mutation; secure-memory zeroization is not claimed.

### Local account discovery

`codexbar serve` exposes saved managed Codex accounts through `GET /accounts` and
`GET /accounts/<id>`, alongside configured provider token accounts. Discovery reads the existing
managed-account metadata only: it never opens managed homes, reads `auth.json`, migrates storage,
refreshes usage, or switches accounts. System and advanced profile-home accounts are not included.
The `active` flag means selected in CodexBar, not necessarily the system Codex identity.

IDs remain stable across identity modes; treat them as opaque lookup keys. Without an explicit
`--identity`, discovery follows the app's **Hide personal information** setting per request.
Redacted mode replaces arbitrary labels with account placeholders and hides email local parts.
Credentials, private paths, fingerprints, and provider-internal workspace IDs are never exported.
See the [account discovery HTTP contract](dashboard-api.md#account-discovery) for authentication,
response fields, and errors.

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
- Enable **Preferences → Providers → Codex → OpenAI web extras** for code review remaining, usage breakdown, and credits history. It loads `chatgpt.com` in a hidden WebView and can materially increase battery/network usage.
- **OpenAI web battery saver** defaults off. It reduces background/settings-driven refreshes while preserving explicit manual refreshes.
- Renewal/expiration dates load after dashboard usage: the subscription API is tried first, then ChatGPT's billing request in the same account-scoped session supplies only the date and renewal flag, within eight seconds. Unavailable/malformed responses retain prior dates; valid empty responses clear them. Cancelled, replaced, disabled, or account-mismatched refreshes cannot attach dates. CLI web capture stays within its remaining fetch deadline.
- Preferences → Providers → Codex → OpenAI cookies (Automatic or Manual).
- URL: `https://chatgpt.com/codex/cloud/settings/analytics#usage`.
- Uses an off-screen `WKWebView` with a per-account `WKWebsiteDataStore`.
  - Store key: deterministic UUID from the normalized email.
- WebKit store can hold multiple accounts concurrently.
- WebView acquisitions retain ownership during page preparation. Store eviction invalidates its pending preparations; evict-all invalidates all. Stale success/failure/timeout retries cannot displace replacements. Ordinary lease release leaves concurrent temporary views valid. Leases retain their cleanup owner independently of the cache and release once: validated pages allow brief reuse; other releases schedule deferred cleanup, including temporary views.
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
- On fully enforcing macOS hosts, standalone hardened-runtime CLI Gatekeeper verdicts are reused for at most five minutes while stat
  metadata and every architecture’s complete embedded signature remain unchanged. Page-protection opt-outs,
  unsigned or malformed files, and app bundles use fresh assessments. A process-wide host check requires full SIP,
  system code-signing enforcement, and readable boot arguments without enforcement overrides; failed or unknown
  checks retain fresh assessment. Malware/quarantine checks run per lookup. npm payload selection also runs on
  every lookup using the launch environment; only the selected standalone native file's assessment can be reused.
  Selected payloads inside app bundles stay uncached, including when reached through symlinks.
  Each identity read binds metadata and signature bytes to one open descriptor, then rechecks the pathname and
  resolved app ancestry after hashing before storing or returning a verdict.
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
  is absent from the shell PATH. Discovery includes the current `codex-cli/bin/codex` launcher and skips known
  npm launchers whose selected native payload is unavailable, with a diagnostic to reinstall `@openai/codex`.
  The launcher's Node interpreter resolves the architecture and optional package location without evaluating `codex.js`;
  the recognized current `bin/codex` or legacy `codex/codex` layout selects the one payload to assess. Transitional
  launchers such as Codex 0.136 fall back to the legacy path only when the current path is absent, matching npm.
  Stale payloads cannot substitute for an existing but unusable selected binary, or a current-only launcher's missing
  binary. Other architectures cannot substitute either. Unknown layouts fail closed. RPC and PTY discovery
  preserve locator rejection instead of repeating an unfiltered `which` lookup. PTY discovery and status diagnostics
  use the caller's environment for preflight, so a rejected Node runtime cannot be rediscovered under the host environment.
  Healthy npm launchers retain
  PATH precedence; bundled fallbacks still require the existing app trust checks.
  Runtime inspection uses the shared executable finder, ignoring relative and empty PATH entries while retaining absolute
  install paths. Nonempty `NODE_OPTIONS` still prevents inspection, so discovery cannot run a working-directory interpreter
  or preload hook before assessing the payload; bundled fallbacks remain available.
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

Account quota and estimated API cost have different coverage. Remote quota can include work with no readable local
token record. CodexBar cannot convert a quota percentage into dollars or recover missing token categories from it.

| Source | Local token/cost coverage |
| --- | --- |
| Native Codex | Supported session and archived-session records in the selected home. |
| Pi / OMP | Supported backend history; enable [Pi](pi.md) for a separate Usage & Spend source. Account-scoped Codex rows stay native. |
| OpenCodex | Opt-in `~/.opencodex/usage.jsonl` (or `$OPENCODEX_HOME/usage.jsonl`), with recorded provider provenance. This is distinct from OpenCode's session database. |
| OpenCode using OpenAI/Codex | No native session import; reusing its OAuth credentials only enables remote quota. The OpenCode Go SQLite reader selects `opencode-go` records. |
| Amp | Account allowances and credits are supported, but Amp session-token history is not imported into Codex costs. |
| Dots / cloud tasks | Included only when supported usage records are available in a scanned local source. There is no dots/cloud usage-history importer. |

Dots can create cloud threads or delegate tasks to a connected computer; see the
[official task documentation](https://learn.chatgpt.com/docs/dots/tasks-and-memory#assigned-work).
A task appearing in the desktop app does not by itself establish local cost coverage. To investigate an omission,
identify its execution location and a redacted model/token record, omitting conversation content and credentials.

Usage & Spend includes this Mac's Codex session home even when the CLI keeps credentials in the OS keyring and
there is no `auth.json`. Local cost estimates do not require account identity or a successful quota refresh.
Managed and profile homes retain their separate history scopes; a home already represented by a visible account
is not added again as a local source. This does not read the CLI's keyring credentials.

For a manual comparison with another development machine, run `codexbar cost --provider codex --remote <ssh-host>`.
Both hosts scan their own native Codex logs once and return separate summaries, retaining their own day boundaries,
pricing provenance, missing values, and incomplete-request counts. Only bounded totals cross SSH. A remote error keeps
the local result and returns a nonzero exit code. See [CLI host reporting](cli.md) for the versioned summary contract.
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
  - Published model aliases resolve through the existing pricing canonicalizer. GPT-5.6 Sol estimates use the
    rates applicable before or after August 21, 2026; see [model pricing](model-pricing.md).
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
  - Native session `thread_settings_applied.thread_settings.service_tier` evidence applies to the following
    `task_started` turn and subsequent turns until another settings event replaces it, using the existing published
    Fast multipliers. The effective thread tier and known Priority turns survive incremental scans and SQLite reopening.
    Without a known tier, or after an unknown tier is applied, pricing retains the Standard fallback;
    subagents do not inherit a parent tier. Live or saved Priority trace evidence remains authoritative, including
    after trace pruning. Compatible stores retain history while older parser revisions reparse within the scan budget.
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
    after every bounded pass, including when an earlier pass already published a valid snapshot. Fresh validated totals
    replace that earlier snapshot before the next sleep; final reconciliation can still lower totals. Publications use
    actual cache timestamps, and the existing power limits and completeness checks still apply.
    A native scan loads exact usage rows once, deferring raw token history and checkpoints until a file changes
    or a fork needs its ancestors. A single-use receipt binds those deferred reads and saves to the original
    connection, database identity and SQLite change observations,
    checking again under the writer lock. Filesystem/anchor and catch-up reconciliation still run at comparison
    time; a concurrent database change requests a rescan. Fresh database opens retain integrity validation.
  - Scan loads retain decoded baselines for up to four recently used cache roots. Transaction-validated freshness and priority-cursor updates share one metadata write and keep the decoded history warm. Content changes, external commits, failed operations, schema changes, and database replacement invalidate reuse. Each load still issues a fresh save receipt and rechecks transcript identity.
  - Up to four recently used cache roots retain validated reader connections and decoded status/activity data.
    External writes invalidate cached data; database replacement or incompatible metadata reopens the reader through
    existing validation on its next access. Every read still reconciles file identities, and detailed report history
    remains transient. Scanner and writer connections keep separate ownership.
  - Cached Codex rows share byte-identical turn-ID strings within each read, reducing retained memory for repeated turns.
    The temporary string index ends with that read; persisted row values, Unicode spellings, and pricing stay unchanged.
  - Report, scan-baseline, and workspace reads decode stored usage rows as SQLite yields them, avoiding a second copy of the
    history as encoded payloads. Metadata and rows share one read transaction; filesystem reconciliation runs after
    it closes. Row order, pricing, malformed-row fallback, and incomplete coverage keep their existing behavior.
  - Saved day/model aggregates group each file's usage rows in one pass per aggregate build. Packed token totals,
    authoritative costs (including zero), and standard/priority estimation buckets retain their existing meanings.
  - Saves skip unchanged files using the transaction-validated scan baseline, so a changed session or scan metadata
    does not rewrite every retained file's metadata, aggregates, fork state, buffers, and accumulator. Changed files,
    parser/calendar migrations, and incomplete persisted row sets still take the normal persistence path.
    Hydrating an empty token history does not force a content rewrite when no snapshot rows are stored for that file.
    Clearing a non-empty history still removes its snapshot rows and preserves sibling histories.
  - Excess cached request rows trigger bounded revalidation of readable, unchanged session files. Ordered source
    replay determines the request sequence; matching token totals alone cannot establish a request partition.
    Unanimous saved pricing survives partial scans and restarts. Files with authoritative monetary amounts, existing
    unpriced markers, or conflicting saved pricing retain their rows without automatic rewriting. Recovered requests
    without matching historical pricing remain unpriced. The repair retains the existing database and scan checkpoints.
    Resumes retain the original target anchor alongside the parsed-prefix anchor and follow the scanner's existing
    append-only log contract; identity changes, anchor mismatches, and unexplained same-size large-file edits invalidate pricing.
    Parser-revision upgrades use the same source validation to preserve matching historical prices when a file
    grows or a recovery scan is interrupted. Appended requests cannot borrow prices from the historical prefix,
    and an invalidated pricing map remains invalid through subsequent upgrades. A saved unpriced request that shares
    its pricing key with a priced request counts as conflicting saved pricing, so neither keeps an estimate. Native stores from 0.62.0's
    `865a444e01b818f1` fingerprint retain their history while individual files are reparsed with corrected accounting.
  - When a model/day's request rows account for its billed tokens, daily reports price the requests with known
    pricing and count the unpriced ones in `unpricedRequestCount` and the priced ones in `pricedRequestCount`. Unpriced
    requests are never estimated from current list prices or folded into an aggregate estimate, and the partial group
    has no Standard/Priority split. A day with any unpriced model or request reports `unpricedRequestCount`, so Usage &
    Spend and the CLI show its cost as a partial estimate. Fully priced days keep the day-level coverage count.
  - Fully read empty session fragments retain completion records even when another file contributes the same session.
    They contribute no usage and reparse from the start if they grow. Usage-bearing duplicates and incomplete fragments
    keep their existing accounting and retry rules. Existing 0.56.4 cost caches are adopted without rebuilding
    stored usage, retained reports, or partial-scan checkpoints.
  - On macOS and Linux, local Priority/Fast pricing evidence comes from native session settings and the host's Codex SQLite trace database.
    Priority trace scans resume after ordinary log pruning when enough distributed content anchors still match;
    changed source rows, replaced databases, or insufficient matching anchors require a fresh scan. Temporary
    trace-database failures retain the last validated report pricing and leave scan freshness unchanged for retry.
    Successful historical queries update their own pricing window independently of the live scan cursor, including
    results with no priority turns; validated pricing outside that window remains intact.
- Window: configurable 1-365 day rolling history.
- Owned `token_usage_record` responses recover usage after resumed-session counter resets. Each response is counted
  once on its event date, with matching legacy `token_count` observations reconciled rather than added again.
  Exact mirrors include their timestamps, so repeated counters cannot erase an earlier legacy-only request.
  Adjacent observations pair when their timestamp or thread cumulative total matches. If counters drift after a
  resume or compaction, observations in the same known turn with identical input, cached, and output tokens can
  pair within five seconds, provided the second counter has not advanced past that request's usage. A delayed
  ledger-first mirror also pairs when both counters advanced by exactly that request since their preceding
  observations, including the first response after compaction. A token_count written before its ledger record uses
  the bounded window. New turns, session resumes, and counted bare usage separate pending observations; these
  boundaries also survive buffered replay. Deferred forks retain the original owned response's continuity evidence
  and match legacy observations in log order after verifying the parent baseline. Total-only observations keep their
  source identity without guessing usage. Identical copies preserve an outstanding match, and older observations
  remain recognized after leaving the bounded counter history; replays cannot claim another nearby request.
  Unowned last-usage-only rows remain independent when no cumulative counter proves they are repeated observations.
  Parser revision 9 reparses existing files once to remove those duplicates while retaining saved prices; a file with
  saved unpriced rows and no reusable saved prices is reparsed with its rows unpriced rather than at current prices.
  An explicit unknown price on the owned row also blocks a priced duplicate from supplying an estimate.
  Legacy snapshots containing only last usage or only cumulative totals also
  reconcile with matching owned responses after the existing counter checks.
  Paired observations retain their response identity across files; the owned response supplies the date while
  matching saved pricing survives replacement of an older legacy page. Parser upgrades look up that pricing with the
  replaced legacy row's own timestamp, because the owned response and its token_count mirror are usually recorded
  a few hundred milliseconds apart; bounded upgrades restore it to a retained ledger row when a later slice reaches
  the mirror. Only the original observation, including a verbatim duplicate, supplies saved pricing; a later replay
  can deduplicate without donating its price. Stores from 0.72.0 (`ed735dc27ffa70d9`) and the saved-pricing fix
  (`99d920977063318a`) are adopted without rebuilding. Existing unknown-price markers stay unknown during reparsing:
  they do not record whether they came from the timestamp mismatch or from invalidated evidence.
  `codexbar cache clear --cost` rebuilds such a cache from the session logs.
  Thread and execution-session identities are validated separately; copied child history remains excluded by the
  existing subagent boundaries. Cached tails retain these identities across refreshes and SQLite reopen.
  Compatible caches retain stored history and matching saved prices while older parser revisions reparse in bounded
  passes. Legacy-only logs retain their existing replay protections; a counter decrease alone does not prove new usage.
- Pending cost scans retain their discovery range when the same cache receives narrower or wider history requests ending on the same day. Reports still use the requested dates, and compatible existing caches retain stored usage and partial-scan progress on upgrade. A new ending day, changed roots/timezone, or a forced rescan keeps the usual discovery reset behavior.
- Routine rescans of changed sessions replace request-pricing rows within the scan window alongside token totals. Cached rows outside that window remain available; obsolete rows cannot make an otherwise priceable day lose its cost estimate. Budget-limited scans retain matching request-pricing evidence and the parser position across restarts, without counting unparsed requests in active totals. Upgrades from 0.60.1 retain saved history, including sessions whose source files are no longer available.
- App cadence: regular timer-driven local-history refreshes have a 15-minute minimum (30 minutes in Low Power Mode).
  Manual disables the recurring refresh timer, not all scan activity: startup refreshes and pending Codex catch-up can
  still scan local history. Faster provider refreshes still update quota/status. The scanner's default 60-second
  debounce is a separate internal limit, bypassed by forced scans and catch-up passes; it is not the app's refresh cadence.
- Usage & Spend catch-up remains inactive after a no-progress or error pause until you choose **Refresh** in the dashboard toolbar or catch-up panel. Opening the dashboard or receiving background updates does not retry those terminal pauses. Low-power and thermal pauses can still recover automatically; this retry policy does not change cached history or token accounting.
- Each catch-up worker permits one recovery per cache when a repeated progress state comes from a time-budget yield before any file attempt or byte read. Automatic recovery waits for the normal cooldown, then uses a full scan budget. Repeated empty passes and semantic cycles still pause; user stops, errors, and power or thermal constraints keep their existing behavior.
- Dashboard synchronization can clear a no-progress pause with a read-only check when another scan has completed the same accounts, roots, time zone, and requested history window. It does not start a scan or override a user stop or error. Completion uses confirmed cache coverage rather than comparing scan start times with the pause time.
- Menu cost catch-up keeps user stops and no-progress/error pauses across scheduled refreshes. Choose **Refresh** to retry after the worker stops. Successful completion still honors queued refreshes for newly discovered history; low-power and thermal pauses can recover automatically.
- Automatic Codex catch-up scheduling in both usage and Spend Dashboard honors the app’s 30-minute Low Power Mode minimum after each pass. Explicit acceleration remains immediate, and physical low-power/thermal pauses retain their own retry policy. The setting applies when the next delay is computed; an already pending sleep is not replanned.
- Automatic catch-up reports thermal pressure when serious heat and Low Power Mode coexist. Both constraints keep the existing 60-second pause before rechecking resource state.
- Automatic catch-up starts without an assumed prior scan delay and continues cheap discovery pages within a two-second burst, capped at eight passes. Each pass receives the remaining scan time, checks normal window readiness, and can publish validated totals before the next sleep. The subsequent duty-cycle delay accounts for the whole burst, excluding waits on the shared account/provider queue. Returning to automatic mode counts only the in-flight accelerated pass toward its next delay. App Low Power Mode still floors each delay, and physical low-power/thermal pauses, no-progress detection, cancellation, and complete-history publication rules still apply.
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
  Stale pending path associations are reconciled in the existing cache. Once bounded discovery confirms a parent is
  missing, fully read forks stop keeping catch-up pending, including descendants of an orphaned fork. Their unresolved
  usage remains buffered and unmetered; a changed parent dependency retries accounting when the parent returns.
  Reporting windows overlapping the fork's observed event span remain incomplete, while independent dates can publish
  normally. A session's start date alone cannot establish that independence. Existing caches retain stored rows,
  replay buffers, and scan checkpoints during this update, including the 0.70.0 parser fingerprint
  `04a6361469a4ff77`. The change settles scheduling and checks coverage from existing metadata; it does not change
  parsed token rows or replay checkpoints, so compatible predecessor caches do not need a rebuild.

### Usage & Spend session rows

Native Codex sessions with validated completed turns show whole-turn output, median model-first-token latency,
and median duration below the cost-ranked header. The optional **Performance details** disclosure includes
sample counts, percentile and cache coverage, and model/effort groups. Timing follows the selected completion
day; billing keeps its existing request dates and range totals. No timing appears when samples are unavailable.
Whole-turn output includes reasoning, tools, and waits; first model token can precede visible answer text.
See the [metric contract and synthetic verification](spend-turn-performance-validation.md).

Projects are grouped by account source and full directory identity, so equal folder names stay separate and
renaming a project does not split its totals. Project and session rows use saved names from the selected Codex
home's project metadata, matching each original rollout directory to the longest root on directory boundaries.
Missing source directories, conflicting labels, or unavailable metadata keep
the folder name. Fresh scans and cached dashboard loads share one metadata lookup per database per refresh;
later loads pick up renames without rebuilding usage history. Worktree sources retain their original directories
when resolving relative SQLite homes.
Metadata reads are bounded to 1,024 roots per database and a SQLite execution budget. If either limit is exceeded,
the lookup keeps folder labels rather than choosing a potentially ambiguous name from an incomplete result.

Duplicate project labels show their paths for disambiguation. **Hide personal information** replaces the labels
with numbered projects and hides those paths, including tooltips. Dashboard-v1 and widget cost summaries contain
aggregate values only, with no project names or directory paths.

Independent desktop chats appear in a separate **Independent chats** section, using saved thread titles or a
neutral chat label instead of generated workspace folder names. Every contributing thread, including older files
from moved threads, must have an explicit marker in the selected Codex home's desktop state. Registered project
roots and current or legacy assignments veto stale markers; missing, malformed, or conflicting ownership keeps
the Projects fallback. A null project ID or an unregistered CLI folder alone never establishes chat ownership.
Project names and ownership share a bounded SQLite snapshot per database per refresh (1,024 roots and 4,096
candidate threads); desktop state reads are capped at 8 MiB. This leaves identities, totals, caches, and dashboard
and widget schemas unchanged. Privacy mode uses numbered chat labels and hides titles and paths through the
existing display identity projection.

Codex session rows show the local thread title when available, with the project, model, and last-activity date
beneath it. Untitled sessions use a shortened session ID. Titles come from `session_index.jsonl`, with the local
thread database as a fallback; relative `CODEX_SQLITE_HOME` paths resolve against each rollout's original working
directory, even when its project is grouped under a different canonical repository path.

Rows rank by cost descending, with unpriced sessions last. Ties use tokens descending, activity time descending,
and source-qualified session ID ascending. The panel initially shows eight rows and can expand to the top 50.
Dates use the dashboard's cost-bucketing time zone. Naming and ranking leave daily totals, the ledger, and existing
per-session costs unchanged; an unpriced session remains unpriced, and a partially priced session shows the subtotal
of its priced requests.

**Hide personal information** replaces titles with shortened session IDs and removes project names and paths,
including from tooltips. Models, dates, tokens, costs, and ranks remain visible. Turning it off restores the names;
this is display masking and does not remove metadata from local history or sanitize exports.

### Usage & Spend account rows

Settings → Usage & Spend performs a separate fixed 30-day scan for every visible Codex account. Each request freezes
the account source, exact Codex home, authentication fingerprint, and cache identity before scanning. A missing or
invalid home is omitted; it never falls back to ambient `~/.codex` or to the global Codex token snapshot.

These account rows intentionally exclude pi and OMP sessions because their history is machine-local rather than owned
by one Codex account. The normal Codex cost menu and CLI scan continue to include supported pi-compatible history. The
dashboard labels its values as local estimates and keeps currencies separate.

Cost refreshes and cached dashboard loads share each file report between session and project views. Daily and
project totals retain their own pricing evidence scopes. All preparation is local to one call, so later loads use
their current rows, prices, roots, dates, and time zone without retaining another report cache.

## Local storage footprint

Storage scans reuse top-level component paths within each scan. Symbolic links stay excluded, and path aliases
and unnormalized roots retain their normalization fallback; directory totals and component names are unchanged.

## Key files
- Web: `Sources/CodexBarCore/OpenAIWeb/*`
- CLI RPC + diagnostic PTY parser: `Sources/CodexBarCore/UsageFetcher.swift`,
  `Sources/CodexBarCore/Providers/Codex/CodexStatusProbe.swift`
- Cost usage: `Sources/CodexBarCore/CostUsageFetcher.swift`,
  `Sources/CodexBarCore/PiSessionCostScanner.swift`,
  `Sources/CodexBarCore/PiSessionCostCache.swift`,
  `Sources/CodexBarCore/Vendored/CostUsage/*`
