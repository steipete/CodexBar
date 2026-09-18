# Antigravity history rendering proof

These images render the production SwiftUI chart views through `NSHostingView` and
`cacheDisplay`, using `AntigravityHistoryNativeProofTests` and synthetic fixtures.
No window is created or shown, and no app, account, credential, or provider is used.
This verifies native chart rendering, not menu interaction end to end.

- `observations.png`: five cadence-less quota samples recorded through `UsageStore`;
  the latest balance is 20% used after an earlier 82% sample.
- `all-unpriced-cost.png`: two unknown-model SQLite records read through
  `AntigravityLocalReader`; 396 tokens, two requests, no dollar total, and the
  production API-estimate/unpriced disclosure.
- `receipt.json`: corresponding production chart model values and disclosure.

Reproduce from the repository root (capture timestamps change with the run):

```sh
source Scripts/test_environment.sh
CODEXBAR_ANTIGRAVITY_PROOF_DIR=/tmp/codexbar-antigravity-proof \
  swift test --jobs 2 --filter AntigravityHistoryNativeProofTests
```
