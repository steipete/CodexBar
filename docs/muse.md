---
summary: "Meta Muse (Muse Code) provider notes: local session log scanning, token cost tracking, and rate limits."
read_when:
  - Debugging Meta Muse local session scanning or rate limits
  - Updating Muse token pricing or model rates
  - Adjusting Muse provider settings or CLI behavior
---

# Meta Muse (Muse Code)

CodexBar tracks [Meta Muse](https://developer.meta.com/ai) token usage and token costs locally from
Muse Code session logs. It reports no quota windows: Meta publishes no local-derivable limits, so
remaining-capacity bars would be invented. Subscription windows need an authoritative account source.

## Data source

- Local Muse Code runtime logs in `~/.local/share/muse/sessions/` (also `~/.config/muse/sessions/` and `~/.muse/sessions/`). Each `model_completed` event carries the model name and token usage; matching `goal_usage_attribution` records are only used as a fallback so calls are never double counted.
- Local settings in `~/.config/muse/settings.json` or environment variables `META_API_KEY` / `MUSE_API_KEY`.
- CLI detection via the `muse` binary (`~/.local/bin`, Homebrew, or PATH); version from `muse --version`.
- Token counts and USD cost are exact from the logs; the account line shows today's and the last 7 days' token totals.
- Contributor accounts (`tier`/`plan` containing `contributor` in `settings.json`) are priced at Contributor rates; each tier keeps its own cost cache (`cost-usage/muse-v1-<tier>.json`).
- Records without a parseable timestamp, negative or absurd token counts (> 1e12), and totals that would overflow are rejected rather than counted.
- If no session directory exists, or it holds no session logs, the provider reports an error instead of an empty 100%-remaining window.

## What It Shows

CodexBar maps Muse usage into standard rate windows and token cost tracking:

| CodexBar field | Muse source | Notes |
| --- | --- | --- |
| Provider id | `muse` | Used by config, CLI, and settings. |
| Display name | `Meta Muse` | Visible in Settings and menus. |
| Identity / plan | `settings.json` `plan` or `tier` | Standard or Contributor ($0.10/$0.20 per 1M tokens). |
| Account line | Local session logs | `Today: N tokens · 7d: N tokens` (today plus the six preceding local days). |
| Rate windows | none | No quota bars; subscription windows need an authoritative account source. |
| Token costs | Local session logs | Aggregates prompt, completion, and cache tokens with standard/contributor rates; Today and 30-day cost in the menu, inline dashboard, and `codexbar cost`. |

## Models & Pricing

- `muse-spark-1.3`: Input $1.25 / 1M, Output $4.25 / 1M, Cache read $0.125 / 1M.
- `muse-code`: Input $1.25 / 1M, Output $4.25 / 1M, Cache read $0.125 / 1M.
- Contributor tier: Input $0.10 / 1M, Output $0.20 / 1M, Cache read $0.01 / 1M.
