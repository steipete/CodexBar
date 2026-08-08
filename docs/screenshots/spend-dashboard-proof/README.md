# Spend dashboard proof

The wide and narrow settings PNGs are rendered by the production
`SpendDashboardHeader` and `SpendTrackedAccessPanel` SwiftUI components. The
Overview capture uses the production `StatusItemController`,
`MenuRowContainerView`, and 310-point menu width. The share capture opens the
production `ShareStatsPresenter` from that Overview.

All provider names, account labels, spend, and token values are synthetic. No
real account data, keys, or usage values are included.

Regenerate the settings PNGs with a full Xcode toolchain:

```sh
CODEXBAR_SPEND_DASHBOARD_PROOF_DIR="$PWD/docs/screenshots/spend-dashboard-proof" \
  swift test --filter SpendDashboardTrackedSourceTests
```

The narrow render verifies that the range controls wrap below the title and the
tracked-source grid collapses to one column. The wide render uses two columns.
Both states keep cost-history inclusion and exclusion explicit.

`overview-all-providers.png` and `share-all-providers.png` are local runtime
acceptance captures rather than golden test outputs. They show the same
six-provider synthetic roster: three sources with known spend and three sources
whose spend is explicitly unavailable. The Overview keeps Codex prominent and
uses compact rows for the remaining providers; the share card preserves all six
connected sources while labeling partial spend and token totals as estimates.
