# Cost window comparison decision

Issues: [#1500](https://github.com/steipete/CodexBar/issues/1500), [#1708](https://github.com/steipete/CodexBar/issues/1708)

## Proposed product shape

Keep the existing history-window setting as the maximum local scan window. Add an opt-in **Show shorter comparison periods** preference, defaulting off. When enabled, the cost card adds fixed 7, 30, and 90-day totals that are shorter than the selected history window.

Examples:

- 30-day history: Today, Last 30 days, Last 7 days.
- 90-day history: Today, Last 90 days, Last 7 days, Last 30 days.
- 365-day history: Today, Last 365 days, Last 7 days, Last 30 days, Last 90 days.

The implementation derives every comparison from the already-loaded daily report. It does not widen scans, add network requests, retain new data, or change provider source selection. Missing calendar days remain zero-usage days rather than making “last 7 days” mean “last 7 non-empty rows.”

## Why this does not claim lifetime cost

“All available local logs” and “lifetime since install” are different contracts. Local Codex, Claude, and Pi logs may be moved, pruned, excluded, or created before CodexBar was installed. The existing plan-utilization history is also capped and has no token or cost ledger. A 365-day total therefore cannot honestly be labeled a lifetime bill.

A true #1708 implementation needs separate approval for an append-only local ledger with:

- an explicit collection start date and completeness state;
- provider/account ownership and reset behavior;
- migration, retention, export, and deletion controls;
- privacy documentation and bounded storage tests;
- UI wording that separates observed utilization snapshots from estimated local-log cost.

Recommendation: ship the opt-in comparison rows for #1500 independently. Keep #1708 open until the ledger/data-retention contract is approved; label any future scan-only total **Available local logs**, never **Lifetime**.

## Maintainer choice

1. **Recommended:** merge with the preference default off. Existing UI and scan cost stay unchanged until a user opts in.
2. Default the preference on. More useful immediately, but adds vertical menu density for existing users.
3. Keep the model only and revisit the presentation. This preserves tested calendar-window aggregation without shipping a new setting.
