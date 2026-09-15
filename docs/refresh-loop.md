---
summary: "Refresh cadence, background updates, and error handling."
read_when:
  - Changing refresh cadence, background tasks, or refresh triggers
  - Investigating refresh timing or stale data behavior
---

# Refresh loop

## Cadence
- `RefreshFrequency`: Manual, 1m, 2m, 5m, 15m, 30m, Adaptive (fresh-install default), and
  Adaptive (agent-aware).
- Stored in `UserDefaults` via `SettingsStore`. An unset cadence resolves to Adaptive only when no prior-launch marker
  or existing config is present, and the resolved value is persisted immediately. Existing installations without a
  stored cadence and unrecognized stored values resolve to the legacy 5-minute fallback. Every valid stored choice,
  including Manual and each fixed interval, remains unchanged.

## Behavior
- Background refresh runs off-main and updates `UsageStore` (usage + credits + optional web scrape).
- Manual “Refresh now” always available in the menu.
- Stale/error states dim the icon and surface status in-menu.
- Optional provider-storage scans run only when “Show provider storage usage” is enabled. They are scheduled in the
  background, coalesced/throttled during automatic refreshes, and forced by manual refresh without blocking the usage
  refresh path.

## Adaptive mode
- `AdaptiveRefreshPolicy` (`Sources/CodexBar/AdaptiveRefreshPolicy.swift`) is a pure function of an `Input`
  (current time, last menu-open time, latest local coding-activity time, Low Power Mode, thermal state) that returns
  the next delay and a stable `Reason`. It reads no clock and no `ProcessInfo` state itself;
  `UsageStore.startTimer()` gathers those impure signals immediately before each tick.
- Policy table, first match wins:

  | Condition | Delay | Reason |
  |---|---:|---|
  | Low Power Mode enabled, or thermal state `.serious`/`.critical` | 30 min | `constrained` |
  | Menu opened at most 5 min ago (including future/clock-adjusted timestamps) | 2 min | `recentInteraction` |
  | Menu opened more than 5 min and at most 1 h ago | 5 min | `warm` |
  | Local Codex or Claude transcript activity observed less than 5 min ago, when the menu rule would be slower | 5 min | `codingActivity` |
  | Menu opened 1–4 h ago | 15 min | `idle` |
  | No recorded menu open, or opened 4+ h ago | 30 min | `longIdle` |

- Every decision falls in the 2–30 min range by construction. Deliberately excludes quota, latency, error,
  account, and time-of-day signals.
- `UsageStore` tracks `lastMenuOpenAt` and `lastCodingActivityAt` in memory only (never persisted; both reset on
  launch). A menu open can bring either adaptive mode forward. A newer local activity observation can affect only
  Adaptive (agent-aware); it never affects plain Adaptive, postpones an earlier tick, or refreshes synchronously.
- Adaptive (agent-aware) reuses `LocalAgentSessionScanner` every 30 seconds only after the user allows local coding
  activity. The
  persisted `adaptiveActivityScanConsent` value is `undecided`, `allowed`, or `declined`; missing or invalid values are
  repaired to `undecided`, which never authorizes a scan. Declining selects plain Adaptive; explicitly selecting the
  agent-aware option again asks again.
- An allowed scan runs `ps -axo ... command=` to inspect the running-process list and identify Codex/Claude, then runs
  `lsof` when needed and enumerates known session metadata only when an agent process is detected. It then reads
  recent Codex rollouts, reads rollout first-line metadata and mtimes, and inspects Claude transcript metadata. When
  the Agent Sessions UI is off, CodexBar discards the resulting session records and retains only the latest `Date`.
  Each scan considers at most 64 agent processes, parses at most 128 Codex rollout metadata records, keeps at most 64
  Claude transcript candidates per project, and shares a 512-entry, depth-1, 150 ms agent-aware directory metadata
  budget. Future
  transcript mtimes are clamped to one scanner-lifetime timestamp. The clamp retains no file paths, and unchanged
  future-dated files cannot manufacture newer activity every 30 seconds.
  Agent-aware scans pause under Low Power Mode and serious/critical thermal pressure. Explicitly enabling Agent
  Sessions continues to authorize its local scan independently of the Adaptive consent choice. Tailscale discovery and
  SSH remain behind the Agent Sessions setting. The activity timestamp is not persisted, logged, or uploaded, and it is
  cleared when consent is revoked.
- Each adaptive tick recomputes the delay after the previous refresh completes, sleeps, then calls the same
  `UsageStore.refresh()` used by fixed-interval mode, so the existing `isRefreshing` coalescing guard still
  applies — only one provider-batch refresh runs at a time regardless of cadence mode.
- Selected delay and reason are logged (e.g. `reason=warm delay=300s` in the `adaptive-refresh` category) through
  the existing local logger; never provider identity, account, email, workspace, path, credentials, or response data.
- Interval-derived heuristics (reset-boundary refresh, OpenAI web staleness, persistent-CLI-session idle windows)
  read `UsageStore.normalRefreshIntervalForHeuristics()`, which resolves adaptive mode to the current decision's
  delay — they stay active in adaptive mode rather than degrading to manual, whose interval is nil.

## Codex window keep-alive (optional, off by default)
- **Settings > Providers > Codex > Auto-start next 5h window** sends one tiny non-interactive prompt after the
  Codex 5-hour window expires, so the next window starts immediately even while nobody is using Codex. It never
  adds quota; it only moves the start of the next window earlier.
- Trigger: the existing reset-boundary refresh. When the boundary that fired belongs to Codex's session window
  (at most 12 h long) and the refreshed snapshot still shows the expired reset, `UsageStore` runs
  `codex exec --skip-git-repo-check --sandbox read-only --json "ping"` through `CodexWindowKeepAliveRunner`
  (`Sources/CodexBarCore/Providers/Codex/CodexWindowKeepAlive.swift`), then refreshes Codex a few seconds later.
- Skipped when the toggle is off, Codex is disabled, Refresh is set to Manual (no reset-boundary task exists, so
  the toggle is greyed out and explains itself), the resolved Background Work Low Power Mode preference is on, an
  added (managed) workspace account is selected, the selected `CODEX_HOME` has no readable ChatGPT login, that
  login is an `OPENAI_API_KEY`, the same boundary was already pinged, no Codex snapshot exists,
  the boundary pass did not publish a *fresh* Codex snapshot (a failed fetch keeps the prior one, which proves
  nothing about the current window), or the refreshed reset is already more than a minute past the expired
  boundary (a new window already started on its own). Decision logic is the pure
  `UsageStore.codexWindowKeepAliveSkipReason(...)`.
- `UsageStore.lastSnapshotPublicationAt[.codex]` is stamped only by successful publications: the ordinary
  `refreshProvider` success path and the stacked-layout selected-account path
  (`applySelectedCodexVisibleAccountOutcome`). Preserved, hydrated, or failed publications never stamp it.
- Workspace admission mirrors `CodexOAuthNativeRefreshCLIStrategy`: `codex exec` only receives `CODEX_HOME`, so it
  would bill whatever workspace `auth.json` names rather than the selected one. Any non-nil
  `managedWorkspaceAccountID` keeps the ping off.
- Subscription only: the ping spends the ChatGPT subscription's 5-hour window and nothing else. API key logins have
  no such window and would be billed per request, so `apiKeyLoginUnsupported` keeps them off; a home with no
  readable login fails closed (`loginUnavailable`).
- The admitted login is bound to the request. `CodexWindowKeepAliveAuthority` captures the fetch environment, the
  SHA-256 of `auth.json`, and the account ID when the boundary admits the ping; right before the CLI launches the
  main actor re-reads the current login and drops the request unless consent is still on and the authority is
  identical. Turning the toggle off (which also cancels the queued task), switching the selected Codex account,
  or replacing the login inside the same `CODEX_HOME` all prevent the request from spending a different account.
- The ping uses the same executable resolution, launch-failure cooldown, and selected-account `CODEX_HOME`
  environment as the RPC usage source, runs in a scratch directory outside any repository, and is bounded by a
  two-minute timeout. One ping per reset costs one small request and writes one short Codex session log.

See also: `docs/status.md`, `docs/ui.md`.
