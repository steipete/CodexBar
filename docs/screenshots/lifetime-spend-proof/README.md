# Lifetime spend proof

These two PNGs are deterministic, synthetic proof for the Usage & Spend **All Time** range.

- `all-time-dashboard.png` renders the production dashboard header and currency section.
- `all-time-share-stats.png` is the production image exported by `ShareStatsRenderer`.

All dates, provider labels, model labels, token counts, and estimated costs come from fixed test fixtures. The renderer does
not launch CodexBar, query providers, import browser cookies, read Keychain items, or load the user's settings and usage
history.

Regenerate the images with the full Xcode toolchain:

```sh
CODEXBAR_LIFETIME_PROOF_DIR="$PWD/docs/screenshots/lifetime-spend-proof" \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter LifetimeSpendScreenshotRenderTests
```

The test always verifies the PNG dimensions and share-text privacy contract. It writes documentation images only when
`CODEXBAR_LIFETIME_PROOF_DIR` is set.
