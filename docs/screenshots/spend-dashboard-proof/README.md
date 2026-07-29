# Spend dashboard proof

These PNGs are rendered by the production `SpendDashboardHeader` and
`SpendTrackedAccessPanel` SwiftUI components at wide and narrow settings widths.
The provider names and account labels are synthetic fixtures; no account data,
keys, or usage values are included.

Regenerate them with a full Xcode toolchain:

```sh
CODEXBAR_SPEND_DASHBOARD_PROOF_DIR="$PWD/docs/screenshots/spend-dashboard-proof" \
  swift test --filter SpendDashboardTrackedSourceTests
```

The narrow render verifies that the range controls wrap below the title and the
tracked-source grid collapses to one column. The wide render uses two columns.
Both states keep cost-history inclusion and exclusion explicit.
