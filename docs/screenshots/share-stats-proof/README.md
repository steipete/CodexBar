# Share stats proof

The PNGs in this directory are rendered by the production SwiftUI share-card
renderer. `share-preview-window.png` captures the real preview window with the
opt-in Model activity style selected.

All values, provider names, and model routes come from a synthetic aggregate
fixture. No account identifiers, prompts, keys, or live usage data are included.
The four cost-history contributors use providers supported by the dashboard
contract: Codex, Claude, Cursor, and Mistral. Four additional fixture sources are
tracked but excluded from cost totals.

With a full Xcode toolchain, regenerate the card sizes with:

```sh
CODEXBAR_SHARE_STATS_PROOF_DIR="$PWD/docs/screenshots/share-stats-proof" \
  swift test --filter ShareStatsTests
```
