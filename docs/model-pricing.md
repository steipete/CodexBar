---
summary: "models.dev pricing metadata pipeline, custom-pricing overlay, cache, lookup rules, and token-cost units."
read_when:
  - Updating models.dev pricing metadata support
  - Debugging model-pricing cache refresh or lookup behavior
  - Routing provider cost calculations through shared pricing metadata
  - Adding or documenting custom-pricing.json overlays
---

# Model pricing metadata

CodexBar uses models.dev as an additive pricing source alongside bundled fallback rates.

## Source and cache

- Source API: `https://models.dev/api.json`
- No API key is required.
- Local cache: `~/Library/Caches/CodexBar/model-pricing/models-dev-v1.json`
- TTL: 24 hours

The pipeline lets future scanner code read the last valid cache synchronously with `ModelsDevPricingPipeline.lookup` and refresh stale metadata separately with `ModelsDevPricingPipeline.refreshIfNeeded`. If a refresh fails, the last valid cache remains usable.

Catalog saves use a single atomic write on macOS and Linux, so refreshing an existing cache replaces its contents without removing the destination first. Successful saves invalidate the in-memory catalog memo.

Fresh OpenCodex dashboard loads and the opt-in CLI OpenCodex payload also refresh the catalog, even when
no native Codex or Claude scan runs. Missing exact provider/model targets may trigger an earlier refresh,
subject to the shared 15-minute retry cooldown. Cached dashboard publication and synchronous snapshot
reads remain network-free. OpenCodex stores raw usage and recomputes estimates from the current catalog;
updating a price does not require rereading unchanged usage logs.

## Lookup rules

Pricing is scoped by provider id and model id. This prevents two providers with the same model id or display name from sharing pricing accidentally.

Local cost scanners preserve that scope when selecting a catalog:

- Bare Codex/OpenAI model IDs use provider id `openai`; approved provider-qualified routes stay on their route, and unknown prefixes remain unpriced.
- Recognizable bare Claude-session model families use their first-party vendor catalog, including Anthropic, OpenAI, Google, Moonshot/Kimi, MiniMax, and DeepSeek.
- Other bare Claude-session IDs are priced only when exactly one selected first-party catalog matches. Ambiguous cross-vendor matches remain unpriced.
- Provider-qualified Claude-session IDs stay on an approved explicit route and never fall through to another vendor.
- Claude's [documented `k3[1m]` alias](https://www.kimi.com/code/docs/en/third-party-tools/claude-code.html) resolves to `kimi-for-coding/k3` after exact-row lookup, including the existing `kimi-coding/` and `kimi-for-coding/` routes. Recorded model names stay unchanged; other context variants and paid Moonshot routes are not inferred. Catalog zero rates remain known estimates, not a claim that subscriptions or extra usage are free.
- Vertex AI Claude logs: models.dev provider id `google-vertex-anthropic`

### Explicit provider identity in OpenCodex

OpenCodex estimates use the recorded provider and model together. An unqualified model on `opencode-go`
uses that provider's rates, not OpenAI's bundled prices. `provider=openrouter` with
`model=openai/gpt-5.4` looks up the exact `openai/gpt-5.4` model inside the `openrouter` catalog.
Only a redundant outer `openrouter/` prefix is removed. Router lookups do not fall back to bare model IDs,
another provider, or OpenAI's bundled/historical tables.

The shared target resolver preserves the existing Kimi/OpenCode provider aliases. Legacy OpenCodex rows
with an `openai` transport label and an explicit supported subscription-route prefix retain that route.
Other providers cannot borrow subscription attribution from a model namespace: an OpenRouter-hosted
OpenAI model does not consume a Codex subscription.

The CLI's separate OpenCodex payload can price any exact recorded provider/model present in the catalog.
This does not enable new ingestion sources or add API providers to the dashboard's subscription fan-out.
Existing Pi provider support and the opt-in OpenCodex setting are unchanged. Dollar amounts remain
list-price estimates; recorded token usage is not a billing receipt. Rows lacking input/output counts,
an exact price, or a consumed cache class's rate stay unpriced. An unpriced current day is not shown as $0.

OpenCodex retains the recorded input, output, cache-read, and cache-creation counters. Non-OpenAI catalog
prices and caller-supplied custom prices charge these independent classes without clamping cache usage
to the input count. Historical OpenAI catalog pricing and all application-overlay calculations retain their
inclusive input convention, including legacy routed rows. No convention is inferred from aggregate total tokens;
missing cache prices remain unknown.

## Units

models.dev publishes costs as USD per 1M tokens. CodexBar converts those to USD per token in the metadata layer:

```text
perToken = modelsDevCost / 1_000_000
```

When models.dev includes `cost.context_over_200k`, CodexBar parses those values as the above-200k-token pricing lane and converts them with the same per-1M-token rule.

## Custom pricing overlay

Exact-match list-price overrides live in the platform Application Support directory:

```text
macOS: ~/Library/Application Support/CodexBar/custom-pricing.json
Linux: ${XDG_DATA_HOME:-~/.local/share}/CodexBar/custom-pricing.json
```

The Linux CLI uses `FileManager`’s Application Support directory (XDG data home), not `~/.config`. Putting the file only under XDG config will be ignored.

Values are USD per million tokens. For native Codex session scans, resolution order is **overlay > models.dev > builtin**. Changing the file invalidates the Codex pricing fingerprint so the next native Codex scan reloads rates.

The overlay applies to native Codex/OpenAI-compatible pricing and OpenCodex estimates. OpenCodex checks
the recorded provider/model identity before its provider catalog; its caller-supplied snapshot overlay
takes precedence over the app-level overlay. Bare model keys remain global overrides with the documented
bare-key precedence below. Use full keys such as `openrouter/openai/gpt-5.4` to scope routed prices.
Claude's local scanner and Cursor do not read this file. A key such as `anthropic/claude-…` does not change
Claude scanner list prices.

Keys are case-insensitive and may be a bare model id (`gpt-5.4`) or `provider/model` (`openai/gpt-5.4`). Only an exact normalized key matches; there is no prefix or family glob. If both forms exist for the same model, the **bare key wins** and the provider-qualified row is ignored. Do not define both unless the bare override is the one you want.

```json
{
  "gpt-5.4": {
    "input": 1.25,
    "output": 10,
    "cacheRead": 0.125,
    "cacheWrite": 1.25
  },
  "openai/gpt-5.4-mini": {
    "input": 0,
    "output": 0
  }
}
```

Field rules:

- `0` is a free rate for that token class.
- A missing field stays unknown. CodexBar does not fill it from models.dev or bundled tables, so a partial overlay row is unpriced rather than a mix of overlay and catalog rates.
- Negative and non-finite numbers are ignored.
- Alternate spellings `cache_read`, `cache_write`, `cacheCreation`, and `cache_creation` are accepted for cache fields.

Tests never read this file from the developer Application Support directory; they use fixtures or an empty overlay.
