# 2026-07-11 Cursor and OpenCode parity

- Plan approval: Codex Review Loop approved the revised implementation plan after four rounds.
- Task 1 baseline: the focused Cursor, widget, and OpenCode parser suites passed before characterization changes.
- Regression contracts added: selected Cursor range/date persistence, approximate totals, weighted request diagnostics, and backward-compatible snapshot decoding.
- SwiftPM test-target compilation constraint handled: pre-implementation assertions use serialized snapshot output and existing menu seams until the later typed presentation APIs land.
- Task 2: verified existing normalization/pricing regression coverage and restored aggregate exact, bounded, and lower-bound estimate formatting without adding an unverified model rate.
- Task 3: persisted selected Cursor range totals/date windows and presentation-ready cost text in a backward-compatible widget snapshot, with newest-first request rows capped independently from aggregates.
- Task 4: restored inline Cursor request diagnostics for model, timestamp, weighted cost, token/cache breakdown, estimate source, and caveat text while preserving the 30-row cap and scroll-forwarding interaction policy.
- Task 5: added Codable OpenCode workspace-account records with canonical credential/workspace IDs, active-account pruning/fallback, explicit mutation results, injected-session discovery of sanitized workspace labels and owners, and an additive provider settings snapshot account-ID field.
- Task 6: wired OpenCode workspace accounts through settings import/manual-add/remove flows, active workspace snapshots and stale-response guards, token-account pruning, and a display-safe generic menu switcher that leaves Claude/Copilot behavior intact.
