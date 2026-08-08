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
uses the production `ShareStatsWindowController`, preserves all six connected
sources, labels partial spend with its reporting denominator, and ranks routed
OpenRouter models alongside first-class Claude and Codex variants.
