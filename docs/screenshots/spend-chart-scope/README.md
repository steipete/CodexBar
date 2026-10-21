---
summary: "Synthetic rendering and regression proof for scoped spend chart inspection."
read_when:
  - Reviewing spend chart date selection and source visibility
---

# Spend chart scope proof

`SpendTrendChartRenderTests` renders the production `SpendDashboardTrendPanel` with synthetic dates,
account labels and amounts. Its 14-image matrix covers daily/hourly, weekly/monthly, light/dark,
wide/narrow and English/Chinese/German layouts.

The scope fixture contains six sources. Four have recorded amounts in the overview range, and three
have hourly records on October 7. Both include Claude with recorded zero-dollar spend. The legend
retains those zero-dollar sources, omits missing/unpriced sources, and preserves account colors and
labels from the full provider list. The amount inspector includes zero-dollar rows and wraps when
needed. The original positive-only captures remain in PR #4329's history; they do not represent the
corrected zero-dollar behavior.

`SpendTrendScopeTests` checks adjacent dates, daily gaps, weekly boundary buckets, missing hourly
records, zero-only source isolation, scoped legends and stale selections. `SpendTrendChartTests`
checks inspection through every real hour of 23-hour and 25-hour DST days, including repeated hours.

Run from the repository root in Bash:

```sh
source Scripts/test_environment.sh
CODEXBAR_SPEND_TREND_PROOF_DIR="$PWD/.build/spend-chart-proof" \
  swift test --build-system native --jobs 4 -Xswiftc -gnone \
  --filter 'SpendTrendScopeTests|SpendTrendChartTests|SpendTrendPresentationRegressionTests|SpendTrendCalendarTests|SpendTrendOverflowTests|SpendTrendChartRenderTests'
```

`13-used-sources-narrow.png` and `14-hourly-used-sources.png` show the corrected source membership.
These are isolated native component renders and model regression tests, not a packaged-app pointer
recording. They do not read real provider accounts or replace the installed application.

## Recorded zero-dollar correction

Before (the contributor's positive-only filter):

![Synthetic hourly inspector before: recorded zero-dollar Claude source is hidden](https://github.com/user-attachments/assets/93ac1244-6a51-4105-953c-5c1f45c8d0ee)

After (recorded zero-dollar source and amount retained; total unchanged):

![Synthetic hourly inspector after: Claude zero-dollar amount and source are visible](https://github.com/user-attachments/assets/0d044b0d-fab0-425c-a8aa-619091cba893)
