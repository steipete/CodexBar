# Recorded quota burndown

Codex and Claude's **Plan Usage** submenu shows recorded remaining quota above the
existing utilization history when a saved quota window has not expired. Each chart
keeps its own selector. Labels and saved-window normalization come from the shared
utilization-chart preparation, including Claude's Sonnet lane and legacy Codex
30-day windows displayed as Monthly.

The solid line joins recorded quota percentages; it is not an exact token count.
The dashed line is an even-use guide from 100% at the window start to 0% at reset,
not a forecast or the learned/workday pace calculation. Each selected series shows
its actual capture age. No line is extended to the current time after the last
capture. Weekly and monthly endpoints include localized calendar dates and times;
session endpoints use compact times. Expired windows disappear from the burndown,
while the utilization history remains accessible below it.

## Retention and privacy

This view adds no persistent store, setting, provider request, or background task.
Codex and Claude already record Plan Usage history during normal refreshes. The
menu reads the history selected by the existing provider/account ownership rules.

Existing JSON files live under
`~/Library/Application Support/com.steipete.codexbar/history/`. Entries contain
capture time, used percentage, and reset time, grouped by quota series, duration,
and account. Existing hourly compaction preserves peaks and reset boundaries;
recording caps each account's series at 17,520 samples (roughly 730 days at one
sample per hour). This is not a strict age expiry, a global byte limit, or an
account-count bound.

The existing account keys are not all anonymous: Codex provider-account keys can
contain the provider's account identifier in plain JSON, while email-based and
Claude keys are hashed. This chart does not change that storage format or add
identifiers. Treat existing history files as private; display masking does not
sanitize them for sharing.

## Synthetic rendering

The render tests exercise the chart views using fixed synthetic dates and samples,
without launching the app, creating status items, reading accounts, or contacting
providers. They always render in both light and dark appearance. To save the PNGs:

```sh
source Scripts/test_environment.sh
env -u OP_SERVICE_ACCOUNT_TOKEN -u SLACK_APP_TOKEN -u SLACK_BOT_TOKEN \
  -u DISCORD_BOT_TOKEN -u GOOGLE_PLACES_API_KEY -u KIEAI_API_KEY \
  -u GOG_KEYRING_PASSWORD -u CLAUDE_CODE_MESSAGING_TOKEN \
  CODEXBAR_BURNDOWN_PROOF_DIR=/tmp/codexbar-burndown-proof \
  swift test --filter QuotaBurndownRenderProofTests
```

The fixture produces Codex Session, Weekly, and Monthly views, Claude's
Weekly/Sonnet selector, and a before/after pair with the retained utilization chart.
These are hosted-view renders, not captures of a running native menu. The hosted
submenu tests separately cover lazy hydration and refresh after a window expires.

The contributor's earlier synthetic captures remain available for comparison:
[original chart](burndown-menu-synthetic.png),
[native submenu](burndown-native-synthetic.png), and
[weekly endpoints](burndown-weekly-synthetic.png).
The standalone debug-app proof mode used for those captures has been removed.
