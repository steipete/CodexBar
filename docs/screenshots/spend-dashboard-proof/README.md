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

`overview-all-providers.png` and `share-all-providers.png` are local synthetic
runtime captures rather than deterministic golden outputs, so they follow the
Mac's active appearance. They show the same six-provider roster: three sources
with known spend and three sources whose spend is explicitly unavailable. The
Overview is captured at the production 310-point menu width, keeps Codex
prominent, and uses compact rows for the remaining providers. The share capture
uses the production `ShareStatsWindowController`, preserves all six tracked
sources, and labels partial spend with its reporting denominator. Its values and
model labels are synthetic UI fixtures rather than claims about live provider coverage.

The three `overview-token-allocation-*.png` files are fixture-driven dark-mode
renders of the production `OverviewSpendSummaryCardView` and
`OverviewMenuCardRowView` at the same 310-point menu width:

- `complete` proves exact 3/3 coverage, the segmented known-token mix, and three
  same-row cost-per-million rates.
- `partial-long-roster` proves a six-provider roster, approximate totals,
  an unavailable rate, and the compact `+3` legend overflow.
- `native-currencies` proves EUR/USD isolation and a positive sub-cent rate
  rendered as `<$0.01 / 1M` rather than `$0.00 / 1M`.

Regenerate these allocation PNGs with a full Xcode toolchain:

```sh
CODEXBAR_OVERVIEW_ALLOCATION_PROOF_DIR="$PWD/docs/screenshots/spend-dashboard-proof" \
  swift test --filter OverviewTokenAllocationScreenshotTests
```

The renderer is opt-in and skips unless the output environment variable is set.
Every fixture is synthetic; the banner in each image makes that provenance
visible to reviewers rather than relying on surrounding PR copy.
