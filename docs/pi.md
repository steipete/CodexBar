---
summary: "Pi and OMP local token history, source selection, and cost accounting."
read_when:
  - Configuring the Pi provider
  - Debugging Pi or OMP session discovery and incomplete history
---

# Pi

Enable Pi in Settings → Providers to show Pi and OMP token history as a separate local source in the menu, Usage & Spend, Overview, and widgets. Pi has no subscription quota or account balance. Costs are API-rate estimates from recorded assistant usage, not a billing statement. No provider login or credential is required to read the transcripts.

The scanner currently supports the `openai-codex` and `anthropic` backends. Other backends keep standalone Pi history incomplete; they do not become measured zero or invalidate the supported Codex and Claude partitions. Supported usage with an unknown model retains its recorded tokens and is marked unpriced. Mixed priced and unpriced history preserves the known subtotal without presenting it as a complete cost.

Cost collection can refresh the public [models.dev pricing catalog](model-pricing.md). Transcript contents stay local; the catalog request needs no credential. Existing cached prices and bundled rates remain available when a pricing refresh fails.

## Session discovery

Default session roots include `~/.pi/agent/sessions` and the supported OMP agent/profile stores. Discovery honors `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR`, OMP configuration/XDG roots, and `OMP_PROFILE` (or `PI_PROFILE` when absent). A named profile limits discovery to that profile. Invalid or unresolved explicit selectors produce incomplete history.

Running Pi/OMP processes also contribute their environment, profile, `--session-dir`, and project settings. Relative paths resolve against that process's working directory. A missing working directory cannot turn an unresolved relative selector into a successful empty scan. Retained roots from explicit command-line or settings selectors survive process exit; settings are revalidated before reuse. Removing a setting from an accessible project drops its former root, while an inaccessible project or broken settings symlink preserves the previous scoped report and its original age.

Assistant turns are bucketed by their own timestamp in the selected cost time zone. Matching entry IDs within the same session count once across overlapping roots. Distinct turns remain separate. The scanner retains per-message prices and token classes rather than repricing a daily aggregate.

## Count each source once

With Pi disabled, unscoped Claude and Codex history can include their supported Pi/OMP backend partitions. With Pi and local cost tracking enabled, the app shows native Claude/Codex history alongside standalone Pi. Combined CLI selections follow the same rule. Account-scoped Codex history always remains native because machine-local Pi history does not establish account ownership. Overview and Usage & Spend use the same source accounting, including during cached hydration and completed Codex catch-up.

```bash
codexbar cost --provider pi --format json --pretty
codexbar cost --provider both --format json --pretty
codexbar cost --provider codex --provider-native-only
```

For a combined report, enable Claude, Codex, and Pi in the config, then run `codexbar cost --format json --pretty` without a provider override. Selecting Pi with Claude/Codex excludes mirrored Pi rows from those native providers. A standalone Claude/Codex selection (including `--provider both`) retains its existing inclusive behavior unless `--provider-native-only` is supplied. The same selection rule applies to dashboard and HTTP cost collection.

## Cache and incomplete history

The cache is `~/Library/Caches/CodexBar/cost-usage/pi-sessions-v9.json` on macOS. It records source scope, coverage, and unsupported-history evidence, and is replaced atomically on macOS and Linux. Version 8 is rebuilt once from transcripts because it did not record sufficient scope and completeness evidence for safe reuse. An unavailable source during this upgrade leaves history unavailable until a valid scan can complete; it does not borrow an old cache's timestamp or totals.

Incomplete refreshes can preserve a previously valid report with its original source scope and scan time. Malformed records, truncated tails, inaccessible roots, and unrepresentable aggregate totals cannot advance cache freshness. Cached and debounced reads check the recorded file inventory and metadata before declaring coverage complete, without reparsing transcripts. Failed root transitions never combine old and new datasets. Missing optional Pi history leaves available native history explicitly incomplete and immediately eligible for another refresh. A verified empty source remains distinct from an uninspected source.

Files replaced while being read leave the refresh incomplete. A pricing-catalog change requires a complete reparse before new estimates replace the prior report. An explicit refresh reparses Pi history even when file size and modification time are unchanged, including Pi usage shown under Claude or Codex.
