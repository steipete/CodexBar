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

Changed catalogs use a single atomic write on macOS and Linux. After fallback pricing is merged, an identical
catalog instead atomically updates `models-dev-v1.json.refresh`, preserving the catalog stamp and cached Claude
reports. The sidecar stores the successful fetch time bound to the catalog's device/inode, size, and modification
time. Both file stamps validate the bounded in-memory catalog memo; missing, corrupt, or mismatched sidecars
fall back to the catalog's embedded fetch time. The 24-hour TTL and 15-minute unknown-model retry cooldown
use the effective fetch time, including after relaunch. The version-1 catalog remains readable by older releases,
which ignore the sidecar and use its embedded fetch time. Successful saves invalidate the decoded catalog memo.

Refreshes preserve cached pricing for removed models using a provider-local stable-identity index. The index and model-ID normalization memo exist only during the merge; lookups likewise build their normalized-ID index only for the current provider and call. These indexes do not change cache lifetimes, provider boundaries, alias precedence, or dated snapshot pricing.

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
- OpenAI's [Daybreak aliases](https://developers.openai.com/api/docs/pricing) resolve like the unsuffixed `gpt-5.6` alias: `gpt-daybreak-blue-latest` prices as `gpt-5.6-sol` and `gpt-daybreak-red-latest` as `gpt-5.6-cyber`. Native usage rows retain raw model evidence; Codex aggregate model IDs follow the canonicalizer.
- Antigravity's Gemini 3.1 Pro aliases (`gemini-pro-default`, `gemini-pro-agent`, and the `gemini-3.1-pro` effort tiers) price as `gemini-3.1-pro-preview`, the only catalogued Gemini 3.1 Pro row. The alias is provider-local; recorded model names stay unchanged.
- Antigravity's safety-routed alias `gemini-3.7-flash-safety-le` prices as `gemini-3.7-flash`: the usage record's model enum ID matches ordinary `gemini-3.7-flash` turns. The alias is provider-local; the recorded model name stays unchanged.
- Antigravity's exact recorded `gpt-oss-120b-medium` name falls back to `google-vertex` / `openai/gpt-oss-120b-maas` after existing model lookups. [Google's Vertex list price](https://cloud.google.com/vertex-ai/generative-ai/pricing) is $0.09 input and $0.36 output per million tokens (verified October 5, 2026); CodexBar reads the rates from [models.dev's catalog entry](https://github.com/anomalyco/models.dev/blob/8ce27fe1f811a0f63100826e9a7965af0afd96d9/providers/google-vertex/models/openai/gpt-oss-120b-maas.toml). Missing cache rates use the input rate, as in the existing Claude resolver. Unknown-price refresh includes this exact entry; other effort suffixes and reseller prices are not inferred. The displayed name stays unchanged, and dollars remain public API estimates rather than Antigravity charges.
- Vertex AI Claude logs: models.dev provider id `google-vertex-anthropic`

Dated Codex usage retains the prior bundled GPT-5.6 Sol rates before **2026-08-21 UTC**, the repricing date in the
[OpenAI changelog](https://developers.openai.com/api/docs/changelog). Current and undated usage use the published
current rates. Terra and Luna retain their separate July 30 cutoff. Custom-pricing overlays retain precedence.

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

When models.dev includes `cost.context_over_200k`, CodexBar converts those rates with the same per-1M-token rule.
The legacy field name does not establish the threshold: a matching `cost.tiers` entry with `tier.type = "context"`
supplies its explicit `tier.size`. Only the tier matching the legacy lane's rates is used; this does not add
arbitrary multi-tier pricing. Older catalogs without that metadata use the bundled OpenAI model threshold,
or 200,000 tokens when no provider-specific contract is known. Other providers never inherit OpenAI thresholds.

OpenAI's [pricing table](https://developers.openai.com/api/docs/pricing) defines short context as **at most 272,000
input tokens**, and long context as **more than 272,000**, including cached input. This applies to GPT-6 Astra,
GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, GPT-5.6 Sol/Terra/Luna, GPT-5.4/5.5, and their Pro variants where listed.
The bundled table preserves that boundary for old catalogs, including the GPT-5.6 and Daybreak Blue aliases.
For example, GPT-6.1 Sol with 210,000 input tokens (200,000 cached) and 1,000 output tokens costs **$0.050** at
Standard rates. At 272,001 input tokens the full request uses long-context rates, not just the excess tokens.
Catalog thresholds and bundled rates participate in the native Codex pricing fingerprint, so affected cached
estimates are repriced. Existing native rows and scan checkpoints remain compatible; recorded authoritative costs
and explicit custom-pricing overrides retain their existing precedence.

## Custom pricing overlay

Exact-match list-price overrides live in the platform Application Support directory:

```text
macOS: ~/Library/Application Support/CodexBar/custom-pricing.json
Linux: ${XDG_DATA_HOME:-~/.local/share}/CodexBar/custom-pricing.json
```

The Linux CLI uses `FileManager`’s Application Support directory (XDG data home), not `~/.config`. Putting the file only under XDG config will be ignored.

Values are USD per million tokens. For native Codex session scans, resolution order is **overlay > models.dev > builtin**. Changing the file invalidates the Codex pricing fingerprint so the next native Codex scan reloads rates.

[Free Codex Auto-review requests](codex.md#cost-usage-local-log-scan) use **overlay > Auto-review waiver ($0) > models.dev > builtin**. A `codex-auto-review` or `openai/codex-auto-review` entry prices them at that rate. Without one, they cost $0, and models.dev and bundled rates never apply.

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
