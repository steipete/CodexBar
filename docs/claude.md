---
summary: "Claude provider data sources: OAuth API, web API (cookies), CLI PTY, and local cost usage."
read_when:
  - Debugging Claude usage/status parsing
  - Updating Claude OAuth/web endpoints or cookie import
  - Adjusting Claude CLI PTY automation
  - Reviewing local cost usage scanning
---

# Claude provider

The **Plan Usage** submenu includes recorded remaining-quota burndown above utilization history,
using the same Session, Weekly, and Sonnet labels. See [recorded quota burndown](widgets/burndown-proof.md)
for capture-age semantics and the existing history retention/privacy behavior.

OAuth history uses a stable account/profile identity after two stable credential observations corroborate that
binding. External token rotations therefore continue the same history after the new credential is corroborated.
Saved token-scoped fragments with matching verified bindings migrate into that account's history on a successful
sample. Unbound fragments, obsolete bindings, and other accounts stay separate; correcting a conflicting binding
preserves its ambiguous old fragment without attributing it to the newly confirmed account. If that fragment was
already merged, the affected account bucket is preserved but hidden, and fresh samples start a new account scope.
This quarantine survives empty responses and restarts. Explicit OAuth tokens without Claude Code account evidence
remain credential-scoped.

Claude supports three usage data paths plus local cost usage. The main provider pipeline uses runtime-specific
automatic selection, but the codebase still has multiple active Claude `.auto` decision sites while the refactor is
pending. For the exact current-state parity contract, see
[docs/refactor/claude-current-baseline.md](refactor/claude-current-baseline.md).

When an Anthropic Admin API key is configured, Claude can also show organization-level spend/messages/tokens in the
same inline dashboard pattern used by the OpenAI API provider.

Incomplete proxy records with an explicit null `stop_reason`, positive input, zero output, and no cache counters are excluded from token and cost totals until a completed record arrives. Their day and model stay visible with an **Incomplete** marker and an excluded-request count. Known usage remains a partial subtotal; an incomplete-only period stays unavailable rather than becoming zero. Older caches are rebuilt once to apply this distinction. Missing `stop_reason` alone retains compatibility with older complete logs.

## Data sources + selection order

### Default selection (debug menu disabled)
- If an Admin API key is configured, the Admin API strategy is used for Claude API spend/usage.
- App runtime main pipeline: OAuth API → CLI PTY → Web API.
- CLI runtime main pipeline: Web API → CLI PTY.
- Explicit picker modes (OAuth/Web/CLI) bypass automatic fallback.
- Explicit OAuth retains the last successful quota measurement through recognized temporary network failures,
  including localized DNS/offline errors. Its original timestamp remains visible; authentication rejection still
  follows the existing invalidation and credential-owner rules.
- A lower-level direct Claude fetcher still contains a separate `.auto` order. That inconsistency is tracked in
  [docs/refactor/claude-current-baseline.md](refactor/claude-current-baseline.md).

Usage source picker:
- Preferences → Providers → Claude → Usage source (Auto/OAuth/Web/CLI).

Admin API key setup:
- Preferences → Providers → Claude → Admin API key, stored in `~/.codexbar/config.json`.
- CLI/env: `printf '%s' "$ANTHROPIC_ADMIN_KEY" | codexbar config set-api-key --provider claude --stdin`.
- Token accounts can also hold `sk-ant-admin...` keys; they route to the Admin API instead of cookie/OAuth usage.
- Environment fallback: `ANTHROPIC_ADMIN_KEY`.

## Admin API
- Key prefix: `sk-ant-admin...`.
- Endpoints:
  - `/v1/organizations/cost_report`
  - `/v1/organizations/usage_report/messages`
- Output:
  - Today/7d/30d spend and message/token summaries.
  - Inline 30-day dashboard chart when daily buckets are present.
  - Identity login method: `Admin API`.

### Optional workspace spend

Enable **Show workspace spend** in Settings → Providers → Claude, set `claudeWorkspaceSpendEnabled: true` on the
Claude provider config entry, or set `ANTHROPIC_ADMIN_WORKSPACE_SPEND=true`. It is off by default and applies only
to the Admin API source.

The existing [cost report](https://platform.claude.com/docs/en/api/admin/cost_report/retrieve) request adds
`group_by[]=workspace_id` alongside `group_by[]=description`; no extra request or credentials are required.
The organization totals, cost items, token summaries, and daily chart remain unchanged. When more than one workspace
has cost rows, **Workspace spend · 30d** shows up to 20 workspaces, highest spend first, over the same 30-day buckets
as the organization total. Labels use workspace IDs; a null workspace is **Default**. Amounts are converted from
Anthropic's USD cents to dollars. A single workspace keeps the existing organization view.

## Recover usage when Claude is already signed in

A working Claude Code login or Claude browser tab does not by itself confirm that CodexBar can read that
session. For example, OAuth can report missing credentials, the CLI probe can time out, and Web can report
`No Claude session key found in browser cookies.` on the same machine. Diagnose the selected source before
signing out or replacing credentials.

If Claude works in Chrome but CodexBar cannot import its browser session:

1. Open `https://claude.ai` in Chrome and confirm the intended account is signed in.
2. In Settings → Providers → Claude, select **Web API (cookies)** and leave the cookie source on **Auto**.
   This uses the browser session for session, weekly, and available model-specific quotas.
3. In Settings → Advanced, confirm **Disable Keychain access** is off. Chromium cookie decryption needs
   the browser's Safe Storage Keychain item; Claude's OAuth prompt policy controls a different credential.
4. Explicitly retry the import from Terminal:

   ```bash
   codexbar cookie refresh --provider claude --allow-keychain-prompt
   ```

   Approve the expected macOS Keychain prompt for the installed CodexBarCLI and the browser's Safe Storage
   item. The command never prints cookie values. A prior denial can suppress imports for six hours;
   this explicit retry can bypass that cooldown, while ordinary refresh attempts may remain suppressed.
   See [Keychain prompts](keychain-prompts.md) for permission details.
5. Click **Refresh** in Claude's settings and confirm that **Updated just now** appears with current quota
   bars and no fetch error. Local cost totals or last-known quota bars alone do not prove a successful refresh.

This recovers browser-session access; it does not repair missing OAuth credentials. If the refreshed session
instead reports a Cloudflare challenge, follow the network guidance under Web API below rather than repeating
the cookie import.

## Keychain prompt policy (Claude OAuth)

- Preferences → Providers → Claude → Keychain prompt policy.
- Options:
  - `Never prompt`: never attempts interactive Claude OAuth Keychain prompts.
  - `Only on user action` (default): interactive prompts are reserved for user-initiated repair flows.
  - `Always allow prompts`: allows interactive prompts in both user and background flows.
- Explicit Refresh can repair Claude OAuth Keychain access when direct-read consent is enabled and the policy
  allows user prompts. Ordinary OAuth fetches remain noninteractive, including with `Always allow prompts`;
  that policy still governs the existing delegated refresh and experimental reader paths.
- This setting only affects Claude OAuth Keychain prompting behavior; it does not switch your Claude usage source.
- The policy also applies to the experimental `/usr/bin/security` reader and delegated OAuth refresh through
  `claude`: background operations that can prompt require `Always allow prompts`.
- CodexBar's `Always allow prompts` permits future prompts; macOS's **Always Allow** grants access to the current
  Keychain item. Claude Code can recreate `Claude Code-credentials` and reset that grant. An ACL entry still named
  CodexBar does not prove that its stored code-signing requirement matches the running binary. `Only on user action`
  reduces background interruptions but may require a manual Refresh to recover OAuth access. In #3798, a
  before/after trace shows Claude Code preserving the decrypt ACL's CodexBar entry but removing CodexBar's Team ID
  from the separate partition ACL. Decrypt-ACL preflight alone cannot establish partition authorization; repeated
  manual grants therefore need not survive the next Claude Code refresh.
- If Preferences → Advanced → Disable Keychain access is enabled, this policy remains visible but inactive until
  Keychain access is re-enabled.

### Debug selection (debug menu enabled)
- The Debug pane can force OAuth / Web / CLI.
- Web extras are internal-only (not exposed in the Providers pane).
- CLI Web enrichment requires matching nonempty account emails; an organization display name alone cannot authorize
  merging another session's optional usage or spend. OAuth enrichment retains verified organization-UUID matching.

## OAuth API (preferred)
- OAuth refresh form-encodes credential values, preserving literal plus signs and other reserved characters.
- Expiry values outside the diagnostic integer range are reported as `out_of_range` without changing credential expiry or refresh decisions.
- Credentials:
  - Explicit OAuth environment override, when configured.
  - CodexBar OAuth cache when available.
  - File fallback: `~/.claude/.credentials.json`.
  - Claude CLI Keychain bootstrap/repair fallback: `Claude Code-credentials`.
- When a CodexBar-owned OAuth cache item's ACL rejects the current build, fresh credentials from an allowed source
  can replace that cache item using no-UI deletion and creation. A locked or inconclusive Keychain is preserved;
  failed ACL repairs back off for five minutes. This never deletes or recreates Claude Code's credential item.
- If CodexBar's cache is temporarily unavailable, automatic refreshes can reuse an unexpired credential already in
  memory beyond the normal 30-minute cache window, ahead of a stale credentials file. Each refresh retries the
  persistent cache. Token expiry, profile changes, cache invalidation, and Never prompt still prevent reuse;
  after a rejected cache write, the next refresh first clears the stale persistent entry, then reuses and persists
  an unexpired in-memory credential even after 30 minutes once that cleanup succeeds. Extended reuse requires
  evidence of that exact failed write and its original consent; an unrelated invalidation cannot authorize it.
  Rejected writes during CodexBar-owned token refresh retain the same recovery, bound to the refreshed credential;
  a delayed older write cannot replace a newer credential's recovery.
  This does not discover an external login or enable additional background reads of Claude Code's Keychain item.
- For the default CLI profile, expired cached or file credentials can adopt a fresh CLI Keychain token after file fallback, even when its fingerprint was already observed during an earlier repair. Existing direct-read consent, prompt policy, cooldown, one-minute freshness-check throttle, and noninteractive-read checks still apply. Custom profiles are not recovered from the unscoped global item, and CLI credentials are never rewritten by this synchronization. Background recovery still requires the Always allow prompts policy; the default Only on user action policy requires an explicit Refresh.
- Credential selection does not rank unrelated sources by the largest `expiresAt`: expiry establishes validity,
  not account identity or issuance order. A valid profile file remains ahead of Keychain bootstrap. Keychain candidates
  are ordered by modification date (creation date as fallback); freshness sync reads only that newest item and never
  rewrites Claude Code's credentials file. An expired default-profile record can be replaced even when the stored
  Keychain fingerprint already matches, subject to the access gates above.
- On Claude Code 2.1.x, `Claude Code-credentials` may contain only MCP server OAuth state (`mcpOAuth`) with no `claudeAiOauth`. CodexBar treats that as an OAuth configuration error, does not run background delegated `claude /status` refresh, and surfaces re-auth guidance. Use Web or CLI usage source, or restore a valid Claude OAuth keychain entry. See #1844.
- Requires `user:profile` scope (CLI tokens with only `user:inference` cannot call usage).
- Missing-scope errors require a Claude Code sign-in token with usage access. `claude setup-token` produces a token for model requests and is not a usage-scope recovery step ([Claude Code authentication](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token)). Remove any configured OAuth token override before switching Claude Source to Web/CLI.
- Endpoints:
  - `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1` → usage and saved reset inventory.
    HTTP 400/403 retries once without the optional query and with the legacy request identity; spending is never skipped.
    Missing-profile-scope errors, 401, and 429 keep their normal handling without that retry.
  - `GET https://api.anthropic.com/api/oauth/profile` → account identity used to verify that optional Web enrichment
    belongs to the same Claude account.
- Headers:
  - `Authorization: Bearer <access_token>`
  - `anthropic-beta: oauth-2025-04-20`
  - Reset inventory uses `claude-cli/<detected-version> (external, cli)`; eligibility remains server-controlled.
- Mapping:
  - `five_hour` → session window.
  - `seven_day` → weekly window; also becomes the primary fallback when `five_hour` is absent or has no utilization.
  - `seven_day_sonnet` / `seven_day_opus` → model-specific weekly window.
  - `limits[].weekly_scoped` → model-specific weekly windows; generic `All models` scopes stay in the main weekly row.
  - The menu localizes scoped titles as a model name plus weekly duration; canonical snapshot and CLI titles remain unchanged.
  - Automatic and Session + Weekly menu bar metrics fall back to the most constrained known scoped weekly window when the regular quota windows are missing. Unknown scoped measurements remain unavailable; Extra usage stays a spend-only fallback.
  - `seven_day_routines` / `seven_day_cowork` → Daily Routines extra window.
  - Claude Design/Omelette keys are ignored because Claude Design shares the main Claude usage limit.
  - `extra_usage` → Extra usage cost (monthly spend/limit).
- Preferences → Providers → Claude → Visible usage items lets you hide the Daily Routines row in menus, the Settings
  preview, and Overview. The global optional credits and extra usage setting remains its master switch. Hiding this
  row does not change fetching, history, notifications, widgets, model-scoped weekly limits, hooks, or CLI output.
- Preferences → Providers → Claude → Show model-specific weekly usage in widgets controls model-scoped weekly quota
  rows in desktop widgets. It is off by default; turning it on displays every known Claude window with a
  `claude-weekly-scoped-` identifier (for example, Fable). Turning it back off also drops scoped rows that a previous
  snapshot persisted. It does not change fetching, the menu, history, notifications, hooks, or CLI output.
- Refreshing credentials for the same identified account preserves quota-threshold warning history. Verified
  credential-owner/account bindings also preserve threshold history when active-account metadata temporarily
  disappears or OAuth falls back to CLI. Threshold warnings re-arm after quota recovers above a threshold and fire
  on a later downward crossing. Predictive warnings and quota-low hooks keep their existing source-scoped histories;
  their baselines are not merged with threshold notification state. OAuth/CLI samples without a warning owner use
  one stable unresolved-account scope, so credential rewrites preserve threshold crossings and predictive warnings
  remain available. When a stable account identity or verified owner binding becomes available, its threshold scope
  adopts the newest unresolved history. Later identity gaps reuse the last known account when the reset timestamp
  is unchanged and remaining quota has not increased. Without that continuity, samples use the stable unresolved
  scope; once its history has joined an account, subsequent gaps preserve already-fired thresholds rather than
  starting a new warning episode on every refresh. The first independent unresolved sample can still issue an
  initial warning. Unverified credential owners remain independent; changing such an owner can still
  produce an initial warning because account continuity cannot be established.
- Successful OAuth login enables Claude and preserves the selected usage source. With the default Auto source, OAuth
  remains preferred when readable, while CLI/Web fallback stays available when OAuth credentials are not usable.
- Claude Code periodically rotates its `Claude Code-credentials` Keychain item and can replace the ACL grant that
  allowed CodexBar to read it. Auto treats that as a failed OAuth source, reuses a recent successful CLI result or
  continues to CLI/Web, and does not misreport the existing credentials as missing. A manual Refresh can re-grant
  Keychain access; selecting CLI or Web avoids the foreign-Keychain dependency.
- When every live Auto source fails, CodexBar keeps the last captured session/weekly percentages from
  `history/claude.json` visible as stale data and shows their capture age instead of blanking the quota bars.
  Restored history and CLI-scraped percentages both show “Limited usage detail”: the warning describes reduced
  fidelity, not the source of a historical capture. It does not change sign-in or refresh recovery actions.
- Plan inference: `subscriptionType` is preferred when present; `rate_limit_tier` falls back to
  Max/Pro/Team/Enterprise. When a Max `rate_limit_tier` carries a usage multiplier
  (`default_claude_max_5x` / `default_claude_max_20x`), it is surfaced in the label as "Max 5x" / "Max 20x".

## Web API (cookies)
- Optional subscription dates come from `GET /api/organizations/{org_id}/subscription_details` on `claude.ai`,
  using an existing manual or cached session cookie. They do not come from the quota response or OAuth expiry.
  `next_charge_at` / `next_charge_date` supply renewal; `plan_ending_at` / `plan_ending_before` supply paid-access
  expiration and take precedence over renewal. Calendar-only dates stay calendar-only when displayed.
- The menu and Settings preview reuse the shared subscription row. Missing, unavailable, or unrecognized billing
  data does not invent a date or fail usage. CLI JSON exposes `subscriptionRenewsAt` / `subscriptionExpiresAt`
  and a corresponding `...IsDateOnly: true` when the server only supplies a calendar date.
- OAuth enrichment additionally verifies the OAuth profile's account and organization against the cookie session
  before and after billing. OAuth credentials alone cannot fetch these dates. No cookie discovery, credential
  repair, sign-in, or new Keychain access is performed for billing; cookie source Off disables it.
- App and CLI use the same provider fetch and normal account-scoped publication. Billing has a separate two-second
  total budget after quota succeeds; expiry, errors, or a changed verified owner leave successful quota intact.
  No delayed billing task writes back into an already published snapshot, and dates are not carried across refreshes.
- Availability is determined by the authenticated billing response, not the Pro/Max/Team/Enterprise plan label.
  The fixtures cover the reported subscription schema, including cancellation and absent dates; they do not
  establish that every plan or organization role can access this endpoint. Team/Enterprise billing access and
  live cancelled subscriptions remain unverified. Quota resets and Extra usage balances are independent.
- Session quota warnings ignore a weekly quota promoted into the primary field when the five-hour payload is missing. Existing session warning history stays tied to its account, and weekly warnings continue independently.
- Preferences → Providers → Claude → Cookie source (Automatic or Manual).
- Manual mode accepts a `Cookie:` header from a claude.ai request.
- Multi-account manual tokens: add entries to `~/.codexbar/config.json` (`tokenAccounts`) and set Claude cookies to
  Manual. The menu can show all accounts stacked or a switcher bar (Preferences → Advanced → Display).
- Claude token accounts accept either `sessionKey` cookies or OAuth access tokens (`sk-ant-oat...`). OAuth-token
  accounts route to the OAuth path and disable cookie mode; session-key or cookie-header accounts stay in manual
  cookie mode. The exact edge-routing rules are documented in
  [docs/refactor/claude-current-baseline.md](refactor/claude-current-baseline.md).
- Cookie source order:
  1) Safari: `~/Library/Cookies/Cookies.binarycookies`
  2) Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
  3) Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`
- Domain: `claude.ai`.
- Linux: the web source supports an explicitly configured manual `sessionKey` cookie. Automatic browser import,
  including Firefox import, remains unavailable. This enables the same API request path as macOS; it does not
  bypass Cloudflare challenges, refresh Claude Code OAuth credentials, or guarantee that a browser session will
  work outside the browser. Use the OAuth source when the web request is challenged.
- Linux CLI Auto mode: an existing valid manual cookie makes Web eligible ahead of CLI after upgrading.
  Web success returns without launching Claude Code; authentication rejection or a Cloudflare challenge falls
  back to an available CLI using the existing Auto policy. Cancellation stops without launching the CLI.
  Explicit Web mode does not fall back. Use explicit OAuth mode for passive polling that must not launch the CLI.
- Cookie name required:
  - `sessionKey` (value prefix `sk-ant-...`).
- Cached cookies: Keychain cache `com.steipete.codexbar.cache` (account `cookie.claude`, source + timestamp).
  Reused before re-importing from browsers.
- After replacing an expired cached cookie, failures from the recovered session retain their actual error type,
  including temporary network failures, server outages, Cloudflare challenges, and cancellation. The original
  sign-in error is retained only when browser recovery itself fails to find a usable session.
- API calls (all include `Cookie: sessionKey=<value>`):
  - `GET https://claude.ai/api/organizations` → org UUID.
  - `GET https://claude.ai/api/organizations/{orgId}/usage?cedar_ember=1` → session/weekly/opus, plus limit-reset
    grants in the `cedar_ember` block. Rejected requests, including ordinary 403 responses, retry once without
    `cedar_ember=1`, so unsupported reset queries keep the usage windows.
    Success, 401, 429, and recognized Cloudflare challenges retain their normal handling without a retry.
  - `GET https://claude.ai/api/organizations/{orgId}/overage_spend_limit` → Extra usage spend/limit.
  - `GET https://claude.ai/api/organizations/{orgId}/prepaid/credits` → remaining Usage credits balance.
  - `GET https://claude.ai/api/account` → email + plan hints.
- Outputs:
  - Session + weekly + model-specific percent used.
  - A missing session measurement does not render as 100% remaining. Measured weekly and extra windows stay visible; when only a synthetic session placeholder exists, menus and plain CLI output report that limits are unavailable. Raw JSON retains the placeholder for diagnostics.
  - Daily Routines extra window when returned by the usage API.
  - Extra usage spend/limit (if enabled). Compact Overview keeps this section when no measured quota bars exist, including Enterprise accounts with unavailable limits.
  - Remaining Usage credits balance (if enabled).
  - Account email + inferred plan.
  - Limit Reset Credits (see below).
- A Cloudflare challenge on `claude.ai` is a network-path restriction, not a stale-cookie signal. CodexBar keeps the
  cached cookie and prior quota snapshot, identifies the challenge, and links to Settings. Select OAuth for live
  quota windows on that network (the web-only Usage credits balance is unavailable), or try a different network.
  Explicit Web mode remains terminal and never reads OAuth credentials as a fallback.
- Limit Reset Credits ("Reset for free" in Claude Settings > Usage), Web and OAuth sources:
  - These are saved resets a user can redeem, separate from the session and weekly reset timestamps already
    supplied by Web, OAuth, and CLI. Existing cookie settings and source selection govern all Web access; this
    feature does not enable cookies, broaden browser discovery, or initiate Web enrichment.
  - Read from `cedar_ember` in the same usage response as the session and weekly windows, so they share its session
    and organization. Observed on a personal Pro/Max account; Team and Enterprise organizations are not verified.
  - The count sums `resets_left` over grants that, at refresh time, are not paused, have started, and have not
    expired. An expiry that passes before the next refresh drops that reset from the display. `usable_now` is not
    consulted, so a saved reset still counts while Claude gates its use.
  - Requires `eligible: true`. A grant with an unreadable `resets_left`, `resets_total`, `paused`, `starts_at`, or
    `ends_at` is dropped. More than 50 available resets or more than 200 grant records show nothing. The usage
    windows are unaffected either way.
  - Menu: a live `Limit Reset Credits` section behind the global optional credits and extra usage setting. CLI and
    `codexbar serve`: a `Limit Reset Credits` row in `usage.details` (`N available`, next expiry).
  - Live-only: grant IDs are never decoded, the usage request skips the URL cache, and cached or synced snapshots do
    not restore the inventory. A reset used on claude.ai disappears at the next successful refresh.
  - Source precedence stays unchanged: credits appear only from the source supplying the primary usage snapshot. CLI
    does not report saved reset credits, and optional Web enrichment never adds Web credits to another source,
    even when the account matches. The menu replaces the generic details row with one shared reset-credit section.
    CodexBar never redeems a reset; use Claude on the web or Claude Desktop.

Enterprise spend details depend on the selected source. Auto stops at the first successful OAuth/CLI/Web result;
it does not import a missing monthly spend cap from a different session. Select **Web API (cookies)** for
browser-only billing details, and enable **Show credits and extra usage** to display them.

## Cloud-session credits

- OAuth and Web usage responses can supply promotional cloud-session credit in `iguana_necktie`.
  CodexBar shows a separate **Cloud credits** balance row in the menu and a detail section in the CLI when
  optional credits/extra usage is enabled. The menu row matches the prepaid **Credits** row and shows only the
  remaining balance; the allowance, progress, and expiry stay in CLI output. CLI JSON exposes the section through
  `usage.details`, including numeric progress and remaining dollars. No additional request, login, or browser
  discovery is needed for these credits.
- `limit_dollars`, `used_dollars`, and `remaining_dollars` are already USD amounts. They are never divided by 100,
  added to prepaid Extra usage, counted as local spending, or used for quota pacing. The reported remaining amount
  wins when present; otherwise it is derived from the allowance and reported used dollars.
- `resets_at` denotes expiration, not a recurring quota reset. The section shows an absolute UTC timestamp
  (`Z`); cached details retain the last observation and its expiry. Exhausted credits retain a zero balance;
  credits already expired at observation or locked by the provider are labeled expired/unavailable. The menu
  also labels a cached balance expired once its stored expiry has passed.
- Missing or malformed credit blocks omit this section without failing ordinary usage. The response determines
  availability, without a Pro/Max plan-name gate. CLI-probe-only results do not include cloud credits, and optional
  Web enrichment preserves the primary source's credits rather than importing Web credits into OAuth/CLI results.
- Settings → Providers → Claude → Visible usage items can hide **Cloud credits** independently. The optional
  credits/extra usage setting remains its master switch; the individual visibility choice does not change CLI output.
- The response shape is based on [Pane's implementation and live-shape test](https://github.com/ItsJazii/pane/blob/beb4bbfd4e7c776d970a56d254e8cce4d61154d9/src-tauri/src/providers/claude.rs#L443).
  CodexBar's fixtures validate parsing and presentation; they are not independent live Pro/Max verification.

## claude-swap accounts (opt-in)

The accepted multi-account design in
[claude-multi-account-and-status-items.md](claude-multi-account-and-status-items.md).

- Setup: Preferences → Providers → Claude → "Read accounts from claude-swap", then set the path to the
  [`cswap`](https://github.com/realiti4/claude-swap) executable (for example `~/.local/bin/cswap`) in the field
  directly beneath the enabled toggle. The path field and its help are hidden while the integration is off.
- Version detection retries after a failed or cancelled startup probe; replaced refreshes cannot overwrite a newer
  result, and disabling the adapter or changing its executable clears the previous detected version.
- Behavior: on each Claude refresh, CodexBar runs `cswap --list --json` independently of the ambient Claude fetch (no
  shell, fixed arguments, bounded runtime and output), requires `schemaVersion == 1`, and parses only slot number,
  active state, usage status, email (display only), display-only `organizationName` (always present, may be empty),
  optional display-only `alias` when non-empty, the 5-hour/7-day windows, and optional display-only model-scoped
  weekly windows from `usage.scoped`, optional `usage.spend`, and source measurement times. Identity stays
  `claude-swap:<slot>`; organization name and alias are never
  used as identity. When two or more slots share an email, cards append ` · organizationName` or ` · Account N`;
  a user-chosen cswap alias replaces that label. Unique emails stay email-only.
- Menu and terminal cards can show the source's `lastGoodUsage` when live usage is unavailable. Its required
  `lastGoodFetchedAt` remains the measurement time, and the card shows a last-known marker and capture age alongside
  the diagnostic. Terminal cards also show the capture timestamp. Malformed additive spend or last-good fields do not
  discard valid live quota windows. The free-form row `message` is not parsed.
  Brief terminal output keeps the diagnostic and excludes historical metrics from its warnings and next-reset summary.
- Last-known usage keeps its provenance through quota retention and cache reload. It never drives the menu-bar icon,
  whose compact display cannot show its age. Compact account rows show the capture age and do not recommend or fold
  last-known rows into the ready-account group. Explicit source measurements take precedence over locally retained
  quota windows.
- Slots excluded from claude-swap's automatic rotation are marked `(disabled)` but remain valid explicit switch
  targets. The active account label is emphasized.
- Display: when claude-swap reports more than one account, its accounts replace ambient/token-account Claude cards.
  The app honors **Menu → Multi-account layout**: Segmented shows account buttons and one active account card;
  pending or failed switches show the requested account's details while the active marker stays source-owned.
  Expired or otherwise unavailable accounts remain inspectable without activation; selecting the active account
  returns to its card. If the adapter reports no active account, the menu says so instead of selecting the first row.
  Buttons wrap into two rows above three accounts. Hide Personal Info uses stable `Account N` slot labels across
  segmented buttons, native account cards, compact menu rows, and accessibility text, including unavailable accounts.
  These numbers come from validated claude-swap slots and remain stable when accounts are reordered; aliases,
  organization names, and email addresses stay hidden.
  Stacked shows one card per account (active account first, then numeric slot). With four or more
  accounts the stacked menu switches to a compact layout (`AccountMenuLayoutPlanner`): the active account keeps its full
  card, inactive accounts become one-line rows sorted by remaining headroom (most constrained first, red/amber below
  50%/10% left, a star on the healthiest activatable account), and healthy rows fold behind a "N more accounts ready"
  summary row. Clicking a compact row expands that account's full card; clicking an inactive card collapses it again.
  This choice is remembered locally across menu opens and app restarts. The summary row reveals the hidden rows for
  the current menu session. `codexbar cards` keeps the full per-account output. The same compact layout applies to
  every stacked multi-account list (token accounts on any provider, and flat Codex account lists; workspace-grouped
  Codex lists keep their sectioned stacked layout). To use this
  presentation with one account, enable “Show account card when only one account is available” or set
  `claudeSwapShowSingleAccount: true` on the Claude provider in the resolved config file (normally
  `~/.config/codexbar/config.json`; legacy installs may use `~/.codexbar/config.json`). The option defaults off,
  zero accounts still use the ambient presentation, and account identity is `claude-swap:<slot>`, never the display
  email.
- Provider widgets follow the active claude-swap account under the same multiple-account/single-account presentation
  rule. Successful list refreshes and clearing the adapter publish a widget snapshot even with account widgets off.
  Retained quota keeps its original measurement time and is bound to the slot's opaque owner fingerprint; unavailable
  or replaced accounts never borrow another account's quota. Local cost history remains combined across Claude homes.
- Terminal scope: this automatic precedence is cards-only and works on every supported CLI platform. An explicit
  Claude provider or `--source auto` remains eligible, while `--account`, `--account-index`, `--all-accounts`, and
  explicit non-auto source flags bypass the adapter. `codexbar usage` and serve `/usage`/`/cost` remain unchanged,
  while `codexbar dashboard` and `GET /dashboard/v1/snapshot` additionally nest one entry per swap account in the
  Claude provider row, with full identity by default or redacted email local parts when `--identity redacted` is set.
- Isolation: CodexBar never reads claude-swap or Claude Code credential storage for this feature; the
  subprocess handles its own credential access. In the app, adapter failures keep the last successful accounts as
  stale data, surface the error in provider settings, and never affect the ambient Claude usage card. In terminal
  cards, a list failure retains the current ambient output, adds a distinct `Claude (claude-swap)` footer entry, and
  exits non-zero.
- Sentinel statuses (`token_expired`, `relogin_required`, `api_key`, `keychain_unavailable`, `no_credentials`,
  `foreign_credential`, and unknown future values) retain per-account diagnostics. Full cards can show explicitly
  reported last-known usage alongside its age; without it they remain notes-only. Brief terminal cards keep the
  diagnostic. When no explicit last-good measurement is supplied and a window is still at 100%, CodexBar keeps that slot's last
  projected usage bars and names the exhausted window (5-hour session, 7-day weekly, and/or a scoped model such as
  Fable) plus its reset time — not "Usage fetch failed." A first refresh that is already `unavailable` with no
  retained windows says usage is unavailable, without assuming why the source could not fetch it. Active rows are marked `[active]`; no claude-swap row infers
  a plan badge.
- Read-only adapters may set top-level `supportsAccountSwitching: false` in their schema-v1 list response. Usage,
  account details, and active markers remain visible, while switching and re-authentication actions are suppressed.
  Omitting the capability preserves existing switching behavior; a present value must be a JSON boolean.
- Switching: an inactive account with usable source credentials shows “Switch Account…”. Clicking it runs exactly
  `cswap --switch-to <slot> --json`, validates the versioned result and requested slot, then refreshes both ambient
  Claude usage and every claude-swap account card. Switches are serialized; no automatic switching occurs. While
  reconciling, the ambient Claude refresh is given five seconds to finish; a stalled refresh continues in the
  background while switching waits for the adapter's active-account list, so it cannot leave the account chips inert.
  A later switch can refresh the adapter list even when its ambient refresh is queued behind an earlier probe. While
  claude-swap owns account presentation, the separate ambient OAuth action reads “Sign in with Claude Code…” and does
  not add or switch a claude-swap account.
- Expired, missing, unknown, or Keychain-inaccessible credentials stay non-actionable. A failed switch remains visible
  on that account without discarding its last successful usage. A running Claude Code process can take up to the
  claude-swap Keychain cache interval to observe the new account.
- A `foreign_credential` row explains that the live credential belongs to another account. An inactive row can use
  the existing explicit slot switch. An active row offers **Re-authenticate**, which runs the same
  `cswap --switch-to <slot> --json` command to let claude-swap reconcile its own credential state, without `--force`. Clicking the active segment
  still only inspects it; repair requires its explicit button.
- Multiple claude-swap accounts—and a single account when explicitly enabled—take precedence over Claude
  token-account presentation (stacked cards and the segmented switcher).

Packaged synthetic proof (fake `cswap` executable, no real accounts or credentials):

![Stacked claude-swap account cards](screenshots/claude-swap-accounts-synthetic-proof.png)

Model-scoped weekly-window proof (synthetic data, no real accounts or credentials):

| Before | After |
| --- | --- |
| ![claude-swap card before scoped windows](screenshots/claude-swap-scoped-before.png) | ![claude-swap card with a Fable scoped weekly window](screenshots/claude-swap-scoped-after.png) |

## CLI PTY (fallback)
- Runs `claude` in a PTY session (`ClaudeCLISession`).
- The PTY and replay screen share a 160-column, 200-row viewport so tall inline `/usage` panels retain their session,
  weekly, and model-specific quotas alongside session statistics and usage insights. Erased content remains discarded.
- The bundled watchdog is discovered only in the running executable's resolved app bundle; launching through a CLI symlink preserves that association.
- Default behavior: exit after each probe; Debug → "Keep CLI sessions alive" keeps it running between probes.
- Both PTY probes and the non-PTY `/usage` fallback pass `--settings '{"remoteControlAtStartup":false,"disableAllHooks":true}'` to disable Remote Control startup and user hooks for the probe process. This process-local override leaves the user's saved settings unchanged; Claude's managed-settings policy still applies.
- Both launches use `--strict-mcp-config` to skip the user's configured MCP servers. Saved nonessential-traffic restrictions remain in force.
- A PTY timeout or usage-loading failure can trigger the non-PTY `/usage` fallback. Cancellation and rate limits stop the probe; a subscription-only notice from the fallback takes precedence over the original PTY failure. An insights-only report is not evidence that the account lacks quotas: it preserves the original PTY failure, which is also logged before fallback.
- Transient CLI timeouts and loading stalls preserve availability already established for that account, so a later
  Auto refresh can retry CLI instead of stopping at missing OAuth credentials. They do not establish availability
  for a previously unverified account; the existing Keychain and prompt policies still apply.
- Probe working directory: `~/Library/Application Support/CodexBar/ClaudeProbe` with local Claude settings that disable
  deep-link URL handler registration during headless probes.
- After transient probes exit, CodexBar removes Claude Code `.jsonl` session artifacts for that dedicated
  `ClaudeProbe` project directory so background `/usage` polling does not clutter the user's Claude project history.
- Command flow:
  1) Start CLI with `--allowed-tools ""` (no tools).
  2) Handle first-run prompts during startup and command capture. For the modern trust dialog, move the `❯`
     selection to "Yes, I trust this folder" before confirming. Modern and legacy trust prompts are accepted only
     in the dedicated probe directory. Redirected paths are rejected before local settings are prepared; headless
     probes require that isolated directory and do not launch from the shared temporary fallback. Transcript cleanup
     is also limited to that directory. An explicitly supplied different working directory never receives trust.
  3) Send `/usage`, wait for rendered panel; send Enter retries if needed.
  4) Dismiss the open panel with Escape before reusing the session for `/status` identity or the next `/usage` refresh.
  5) Optionally send `/status` to extract identity fields.
- Parsing (`ClaudeStatusProbe`):
  - Replays cursor-based `/usage` and `/status` captures onto a bounded screen with the same geometry as the PTY, then locates
    "Current session" + "Current week" headers. Cursor jumps preserve unchanged cells from earlier frames, keeping
    scoped weekly percentages, reset spacing, and account identity intact. Erased content is not reused as history.
  - Plain reports, including color-only ANSI output and legacy CR-delimited text, retain their existing parsing behavior.
  - Capture completion uses the current rendered frame and waits for session quota values; percentages in the
    "What's contributing to your limits usage?" insights section cannot finish a loading quota probe. Once quota is
    complete, insight text cannot trigger another command-palette confirmation.
  - Extracts percent left/used and reset text near those headers.
  - When a reset date cannot be parsed, the menu preserves its description and normalizes leading `Reset` or `Resets` labels once, including scoped weekly limits.
  - Parses `Account:` and `Org:` lines when present.
  - Excludes the "What's contributing to your limits usage?" insights section from quota and identity parsing.
    User-defined tool names and usage-share percentages cannot become a plan badge or quota value.
  - A successful CLI quota read keeps the menu's Switch Account action even when optional identity fields are absent. Restored history and failed refreshes do not count as a successful sign-in.
  - Surfaces CLI errors (e.g. token expired) directly.
  - Some Education and organization-managed subscriptions return only a subscription notice, with no numeric
    session or weekly quota fields. CodexBar reports those limits as unavailable, keeps local cost/token history
    visible, and never derives quota percentages from spend or token totals. Logs and diagnostics classify this as
    a configuration issue and recommend checking the provider source/settings, rather than re-authenticating.

## Cost usage (local log scan)
- Source roots:
  - Native Claude logs:
    - `$CLAUDE_CONFIG_DIR` selects one literal directory and uses `<root>/projects`; commas are part of its path.
    - Also includes claude-swap session profiles at `~/.claude-swap-backup/sessions/<slot>-<label>/projects`. On Linux, also checks `$XDG_DATA_HOME/claude-swap/sessions` (default `~/.local/share/claude-swap/sessions`). Discovery examines only immediate positive-numbered slot directories and their `projects` child; it does not read credentials or run cswap.
    - Fallback roots:
      - `~/.config/claude/projects`
      - `~/.claude/projects` (Claude Code and current Claude Desktop Code/Cowork CLI sessions)
      - Additional embedded Claude Desktop project stores, when present:
        - `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects`
        - `~/Library/Application Support/Claude/claude-code-sessions/**/.claude/projects`
    - Current Claude Desktop metadata under `claude-code-sessions` points to shared CLI session JSONL by
      `cliSessionId`; metadata-only directories are not treated as usage sources.
  - Supported pi-compatible sessions:
    - `~/.pi/agent/sessions/**/*.jsonl`
    - `~/.omp/agent/sessions/**/*.jsonl`
- Files: `**/*.jsonl` under the native project roots, discovered Claude Desktop project roots,
  plus supported pi-compatible session files.
- Parsing:
  - Native Claude logs parse lines with `type: "assistant"` and `message.usage`.
  - Claude/Vertex filtering checks raw lines for possible metadata markers before walking decoded metadata. IDs and model names are checked in their decoded fields, so `@` and `_vrtx_` in tool content do not trigger that walk. Vertex-only scans skip decoding lines without any possible marker; escaped markers retain the full classifier and existing attribution rules.
  - Uses per-model token counts (input, cache read/create, output).
  - Oversized local token or cost values cannot crash history scanning. An overflowing token total stays unavailable while independent counts and finite dollar estimates remain visible; raw rows are retained for later repricing.
  - Deduplicates cumulative streaming chunks by `message.id + requestId`. When `requestId` is absent,
    exact, nonblank `sessionId + message.id` identifies repeated response snapshots. Distinct explicit request
    IDs and distinct fallback sessions remain separate. Rows without sufficient identity are counted individually.
    Within a file, the final complete cumulative chunk wins, including later appends. Copied records retain the
    existing preference for parent and non-sidechain records.
  - pi and OMP sessions attribute `anthropic` assistant usage to Claude and bucket it by assistant-turn timestamp, so a
    single pi-compatible session can contribute to multiple models/days.
  - Matching assistant entry IDs within the same session are counted once across roots; distinct turns are retained. If a Pi/OMP mirror scan is incomplete, established native spend remains usable as a marked partial estimate. The combined history is still incomplete, and native-only reports keep their own coverage.
  - Claude-swap history contributes to the combined Claude total, including when an explicit `$CLAUDE_CONFIG_DIR` is set. Shared-history symlinks are scanned once, copied responses use the same deduplication as native logs, and missing profile directories do not prevent other homes from contributing. Local cost records do not establish per-account attribution.
- Quota-week menu cards reuse the immutable snapshot’s day projection, warmed in the background. New snapshots and changed bucket time zones rebuild it; reset observations and the current time remain live on every card build.
- Cache:
  - GPT usage recorded through Claude Code uses the bundled OpenAI model's long-context boundary (272K for supported models), while retaining catalog rates. Uncached input and cache-read/create tokens all contribute to the prompt length. Saved reports are recalculated after pricing corrections without discarding retained Codex history.
  - Native provider cache: `~/Library/Caches/CodexBar/cost-usage/claude-v6.json`
  - Report memo: `~/Library/Caches/CodexBar/cost-usage/claude-v6.report-memo.json` stores source stamps and the daily report across launches. It is reused only while transcript inventory, cache/pricing artifacts, requested window, and report-semantics revision still match.
  - A pricing catalog replacement during a refresh preserves certification of the parsed transcript window. The next refresh applies the replacement prices to cached rows without reparsing unchanged transcripts, including after a restart. Externally replaced transcript caches still require window certification again.
  - Unchanged sources reuse the memo even when a menu refresh bypasses the scan debounce. Explicit rescans still reparse transcripts, but identical cache and report-memo content is not rewritten; an unchanged rebuild retains its previous scan timestamp. Existing artifacts may be rewritten once to establish deterministic key ordering. Changed transcripts or report metadata still replace the corresponding complete JSON artifacts.
  - Persistence keeps at most eight lightweight artifact identities independently of the decoded-row cache. An unchanged cache identity plus matching device/inode, size, and nanosecond mtime skips encoding; otherwise sorted JSON fingerprints avoid full-file read-back while preserving identical rebuilds. External replacement invalidates reuse, and changed files still use temporary-file rename. Evicted identities are re-established on load or the next save.
  - Decoded cache artifacts can be reused in memory while their canonical path, file identity, size, and nanosecond modification time match. Schema and time-zone checks still run on every load; report-level source, window, filter, and pricing checks still run separately. Atomic replacements invalidate this reuse, and explicit rescans still reparse source transcripts.
  - Successful cache saves retain the just-written decoded value, avoiding another full row decode on the next changed refresh. Unmodified loaded values skip encoding and writing while the artifact stamp still matches; external replacements, deleted files, and failed or cancelled saves cannot establish this reuse. Changed content still replaces the complete JSON artifact. Compact row field names reduce its size; schema 3 artifacts rebuild from transcripts once when the rows are next needed. Report memos and user-facing JSON retain their existing formats.
  - The app's Usage & Spend refresh uses `claude-history-v6.json` and its own report memo. The two app refreshes do not replace each other's retained rows or restart each other's transcript scans. Once both have established their windows, same-day append refreshes read changed tails once per cache.
  - App memos record whether every file's rows were selected for their scan window. Older or externally replaced caches without that proof rebuild once, even if their stored bounds already match; app window changes also rebuild to preserve cold-scan duplicate selection. The regular cache filename and row schema remain compatible, and standalone CLI range behavior is unchanged.
  - The Claude/Vertex cache artifact retains source file identities independently of the shared Codex parser fingerprint. Replacing a transcript rebuilds its rows rather than merging an old prefix into a new suffix; genuine appends still use the saved parse offset. Older entries without identity are rebuilt once before reuse, including during the normal refresh debounce.
  - Older Claude/Vertex native caches and report memos are rebuilt once from unchanged transcripts to apply the corrected response deduplication. Corrected reports remain eligible for memo reuse across launches.
  - pi-compatible session cache: `~/Library/Caches/CodexBar/cost-usage/pi-sessions-v9.json`. Version 8 rebuilds once from transcripts to establish source scope and completeness. Enabling the standalone [Pi provider](pi.md) keeps Claude history native-only in combined views.

## Key files
- OAuth: `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/*`
- Web API: `Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift`
- CLI PTY: `Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift`,
  `Sources/CodexBarCore/Providers/Claude/ClaudeCLISession.swift`
- Cost usage: `Sources/CodexBarCore/CostUsageFetcher.swift`,
  `Sources/CodexBarCore/PiSessionCostScanner.swift`,
  `Sources/CodexBarCore/PiSessionCostCache.swift`,
  `Sources/CodexBarCore/Vendored/CostUsage/*`
