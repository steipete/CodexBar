---
summary: "Refresh cadence, background updates, and error handling."
read_when:
  - Changing refresh cadence, background tasks, or refresh triggers
  - Investigating refresh timing or stale data behavior
---

# Refresh loop

## Cadence
- `RefreshFrequency`: Manual, 1m, 2m, 5m, 15m, 30m, Adaptive (default fallback).
- Stored in `UserDefaults` via `SettingsStore`. A missing or unrecognized stored value resolves to Adaptive. Because the
  old implicit 5-minute fallback was not persisted, existing installations without a stored value also transition to
  Adaptive. Every valid stored choice, including Manual and each fixed interval, remains unchanged.

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
  | Menu opened within the last 5 min (including future/clock-adjusted timestamps) | 2 min | `recentInteraction` |
  | Menu opened 5 min–1 h ago | 5 min | `warm` |
  | Local Codex or Claude transcript activity observed within 5 min, when the menu rule would be slower | 5 min | `codingActivity` |
  | Menu opened 1–4 h ago | 15 min | `idle` |
  | No recorded menu open, or opened 4+ h ago | 30 min | `longIdle` |

- Every decision falls in the 2–30 min range by construction. Deliberately excludes quota, latency, error,
  account, and time-of-day signals.
- `UsageStore` tracks `lastMenuOpenAt` and `lastCodingActivityAt` in memory only (never persisted; both reset on
  launch). A menu open or a newer local activity observation can bring a pending adaptive tick forward, but never
  postpones an earlier tick or refreshes synchronously.
- Adaptive reuses `LocalAgentSessionScanner` every 30 seconds. The scan runs `ps` and, when needed, `lsof`, enumerates
  recent Codex rollouts, reads rollout first-line metadata and mtimes, and inspects Claude transcript metadata. When
  the Agent Sessions UI is off, CodexBar discards the resulting session records and retains only the latest `Date`.
  Each scan considers at most 64 attributable processes, parses at most 128 Codex rollout metadata records, and keeps
  at most 64 Claude transcript candidates per project.
  Adaptive-only scans pause under Low Power Mode and serious/critical thermal pressure. Tailscale discovery and SSH
  remain behind the explicit Agent Sessions setting. The activity timestamp is not persisted, logged, or uploaded.
- Each adaptive tick recomputes the delay after the previous refresh completes, sleeps, then calls the same
  `UsageStore.refresh()` used by fixed-interval mode, so the existing `isRefreshing` coalescing guard still
  applies — only one provider-batch refresh runs at a time regardless of cadence mode.
- Selected delay and reason are logged (e.g. `reason=warm delay=300s` in the `adaptive-refresh` category) through
  the existing local logger; never provider identity, account, email, workspace, path, credentials, or response data.
- Interval-derived heuristics (reset-boundary refresh, OpenAI web staleness, persistent-CLI-session idle windows)
  read `UsageStore.normalRefreshIntervalForHeuristics()`, which resolves adaptive mode to the current decision's
  delay — they stay active in adaptive mode rather than degrading to manual, whose interval is nil.

## Optional future
- Auto-seed a log if none exists via `codex exec --skip-git-repo-check --json "ping"` (currently not executed).

See also: `docs/status.md`, `docs/ui.md`.
