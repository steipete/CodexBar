# Model pricing metadata

CodexBar has an additive models.dev pricing pipeline for future cost lookup work. Existing hardcoded pricing remains unchanged for now.

## Source and cache

- Source API: `https://models.dev/api.json`
- No API key is required.
- Local cache: `~/Library/Caches/CodexBar/model-pricing/models-dev-v1.json`
- TTL: 24 hours

The pipeline lets future scanner code read the last valid cache synchronously with `ModelsDevPricingPipeline.lookup` and refresh stale metadata separately with `ModelsDevPricingPipeline.refreshIfNeeded`. If a refresh fails, the last valid cache remains usable.

## Lookup rules

Pricing is scoped by provider id and model id. This prevents two providers with the same model id or display name from sharing pricing accidentally.

Planned local source mapping:

- Codex/OpenAI logs: models.dev provider id `openai`
- Claude logs: models.dev provider id `anthropic`
- Vertex AI Claude logs: models.dev provider id `google-vertex-anthropic`

The first integration PR only adds the parser, client, cache, provider-scoped lookup, and tests. It does not route live cost calculations through models.dev yet.

## Units

models.dev publishes costs as USD per 1M tokens. CodexBar converts those to USD per token in the metadata layer:

```text
perToken = modelsDevCost / 1_000_000
```

When models.dev includes `cost.context_over_200k`, CodexBar parses those values as the above-200k-token pricing lane and converts them with the same per-1M-token rule.
