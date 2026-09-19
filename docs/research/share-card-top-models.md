# Shared usage card: retained top models

Rendered 2026-09-18 against `fix/share-card-top-models-partial`.

`ShareStatsCardView` is a pure function of `ShareStatsPayload`. These images were produced by compiling the view verbatim with the payload types and `ShareStatsFormatting` from this branch, then rendering through `ImageRenderer` at `1200x630`. `UsageFormatter.currencyString` and `SpendDashboardSource.scanDays` are stubbed; neither affects the TOP MODELS column.

Payload: three USD subscriptions (Codex, Claude, Antigravity). Antigravity is unpriced, so the currency group is incomplete. Synthetic totals only.

| Image | What it shows |
|---|---|
| `before-partial.png` | 0.61.0 / main behavior: group incompleteness drops every model, empty copy, header `BY USAGE` |
| `after-partial.png` | this PR: retained GPT / Claude / Gemini rows, header `PARTIAL`, no numeric ranks |

The layout images above still use a copied `ShareStatsCardView`. Production-path coverage is `builder payload renders a partial model card through the production exporter`: `ShareStatsBuilder.make` → `ShareStatsRenderer.pngData` (`NSHostingView`) → copied text. Set `CODEXBAR_SHARE_STATS_SCREENSHOT_DIR` to persist that PNG and `.txt`.

## Live 0.61.0 check (installed Homebrew cask)

- OpenRouter Activity on the official API now returns last-30-day totals (tokens, requests, model count). The deprecated `-1 requests / 10s` rate limit is gone (#3720).
- `codexbar cost` still skips OpenRouter/Grok/xAI: that command is local JSONL only (`Antigravity, Claude, Codex, Cursor`). Activity spend is a snapshot feed, not that scanner.
- The share-card emptiness is independent of OpenRouter Activity: Codex and Claude already had complete model rows; Antigravity unpriced coverage blanked the USD ranking.

## Related

- #3704 / #3722 — spend-first layout and sparkline; they still need the models column to have something to show
- #3713 — gateway `vendor/model` families (needed once OpenRouter Activity rows reach the builder)
- #3696 / #3272 / #3717 / #3720 — OpenRouter pay-as-you-go, Activity, reasoning tokens, deprecated rate limit
