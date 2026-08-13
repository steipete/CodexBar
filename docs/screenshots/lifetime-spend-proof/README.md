# Lifetime spend proof

These two PNGs are privacy-safe packaged runtime proof for the Usage & Spend **All Time** range.

- `all-time-dashboard.png` renders the production dashboard header and currency section after a real ledger reload.
- `all-time-share-stats.png` is the production image exported by `ShareStatsRenderer` from that reloaded model.
- `record-manifest.json` records the first packaged process, its 30-day ledger hash, and verified `0600` ledger mode.
- `reload-manifest.json` proves the second packaged process opened that exact ledger hash, retained `0600` mode, and
  rendered 60 tracked days.

All dates, provider labels, model labels, token counts, and estimated costs come from fixed synthetic Codex JSONL. The
proof script packages the debug CodexBar app and runs its binary twice in separate processes. The first process scans a
30-day synthetic window through `CostUsageFetcher` and records it with `SpendHistoryLedger`. The second scans a later
30-day window, reloads the same ledger, selects All Time, and emits the dashboard and share-card PNGs from the production
views. The reload manifest's `ledgerBeforeSHA256` exactly matches the record manifest's `ledgerAfterSHA256`.
Both version 2 manifests include `ledgerPermissions: "0600"`, recorded only after the final ledger path independently
passes the packaged runner's exact-mode check.

The proof mode resolves before normal app initialization and is compiled out of release builds. It fails closed unless its
root is a private, current-user-owned, non-symlink directory matching `/private/tmp/codexbar-lifetime-proof.*` with a
regular sentinel file. It constructs no `SettingsStore`, `UsageStore`, browser importer, provider network client, or
Keychain service. The packaged processes receive an empty environment except for a minimal tool path, locale, isolated
home/temp directories, and the proof controls.

Regenerate the complete two-process proof with the full Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./Scripts/verify_lifetime_spend_runtime_proof.sh
```

The script retains its output under a newly created private temporary directory and prints that path. Before reporting
success it requires exactly two PNGs, both version 2 manifests, an independent `0600` mode check after each packaged
process, matching manifest permission assertions, and a manifest privacy scan. The tracked manifests omit the temporary
root and run sentinel UUID; the screenshots show only Codex, `gpt-5.4`/GPT, and aggregate synthetic values.
