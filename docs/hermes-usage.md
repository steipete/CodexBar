---
summary: "Read local Hermes Agent token attribution from CodexBar."
read_when:
  - "You use Hermes Agent and want provider/model/task token totals."
  - "Changing Hermes state.db parsing or provider mapping."
  - "Reviewing billed, included, or API-equivalent cost semantics."
---

# Hermes Agent local usage

`codexbar hermes-usage` reads Hermes Agent's local SQLite attribution data without importing Hermes credentials,
calling Nous Portal, or scraping a browser dashboard.

```bash
codexbar hermes-usage
codexbar hermes-usage --provider codex --json --pretty
codexbar hermes-usage --database ~/.hermes/profiles/work/state.db --refresh-pricing
```

Without `--database`, CodexBar discovers `~/.hermes/state.db` plus `~/.hermes/profiles/*/state.db`. Explicit
comma-separated database paths replace discovery. State snapshots and arbitrary recursive matches are not scanned.

## Safety and accounting contract

- SQLite opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, `mode=ro`, and `PRAGMA query_only = ON`. The normal
  connection remains WAL-aware, so committed rows in a live `state.db-wal` stay visible.
- The scanner reads `session_model_usage` and reconciles only positive residuals from `sessions`. This matches Hermes'
  own Insights behavior for legacy data and absolute cumulative updates without counting attributed route deltas twice.
- Auxiliary tasks such as `vision`, `compression`, and `title_generation` are included. An empty task is reported as
  `agent`.
- Total tokens are `input + cache_read + cache_write + output`. `reasoning_tokens` is reported separately because it
  is a subset of output, not an extra token bucket.
- `auto`, `custom`, empty/unknown, and other ambiguous routes are reported under `unmapped`; a model name alone never
  overrides missing resolved billing metadata.
- Hermes rows are cumulative per session/model/route/task. The command reports a current snapshot, **not exact daily
  history**. `first_seen` or `last_seen` is not used to assign all cumulative tokens to one day.

Costs deliberately remain separate:

- `actualCostUSD`: provider-reported billed cost stored by Hermes. `nil` means unknown, not `$0`.
- `hermesEstimatedCostUSD`: Hermes' stored estimate when its status is `estimated` or `actual`. Subscription-included
  rows do not become a fake `$0` estimate.
- `subscriptionIncludedTokens` / `subscriptionIncludedRequests`: usage covered by a subscription route such as
  `openai-codex`.
- `apiEquivalentCostUSD`: independent standard-rate estimate from CodexBar's cached models.dev catalog. Subscription
  routes use the corresponding direct vendor catalog rather than zero-valued plan pricing. Unknown model pricing stays
  unpriced instead of becoming `$0`.

The Hermes source is intentionally **not auto-added** to provider-native billing totals. OpenAI Admin, Anthropic Admin,
Bedrock Cost Explorer, and similar sources may already include the same API calls; merging them without request-level
identity would double count. Consumers can inspect the standalone Hermes report and choose their own ownership policy.

## Provider mapping

The mapping is conservative and keyed by Hermes' persisted canonical `billing_provider`, not by the selected model.
The audit test classifies every canonical Hermes route known on 2026-08-12.

| Hermes billing provider | CodexBar provider | models.dev rate source |
| --- | --- | --- |
| `openai-codex` | Codex | `openai` |
| `openai-api` | OpenAI | `openai` |
| `anthropic` | Claude | `anthropic` |
| `gemini` | Gemini | `google` |
| `vertex` | Vertex AI | `google-vertex` |
| `openrouter` | OpenRouter | `openrouter` |
| `fireworks` | Fireworks | `fireworks-ai` |
| `bedrock` | AWS Bedrock | `amazon-bedrock` |
| `xai` | xAI | `xai` |
| `xai-oauth` | Grok | `xai` |
| `deepseek` | DeepSeek | `deepseek` |
| `zai` | z.ai | `zai` |
| `alibaba` | Qwen Cloud | `alibaba` |
| `alibaba-coding-plan` | Alibaba | `alibaba` |
| `qwen-oauth` | Qwen Cloud | `alibaba` |
| `kimi-coding` | Kimi; Moonshot when resolved to `api.moonshot.ai` | `moonshotai` |
| `kimi-coding-cn` | Moonshot | `moonshotai-cn` |
| `minimax` | MiniMax | `minimax` |
| `minimax-oauth` | MiniMax | `minimax`; `minimax-cn` for the China host |
| `minimax-cn` | MiniMax | `minimax-cn` |
| `copilot`, `copilot-acp` | Copilot | `github-copilot` |
| `opencode-zen` | OpenCode | `opencode` |
| `opencode-go` | OpenCode Go | `opencode-go` |
| `stepfun` | StepFun | `stepfun-ai`; `stepfun` for the China host |
| `xiaomi` | Xiaomi MiMo | `xiaomi` |
| `kilocode` | Kilo | `kilo` |
| `ollama-cloud` | Ollama | `ollama-cloud` |
| `deepinfra` | DeepInfra | `deepinfra` |

Intentionally unmapped canonical routes are `actual`, `ai-gateway`, `arcee`, `azure-foundry`, `custom`, `gmi`,
`huggingface`, `lmstudio`, `moa`, `nous`, `novita`, `nvidia`, `tencent-tokenhub`, and `upstage`. They are virtual or
custom routes, or CodexBar has no equivalent first-party provider identity. They remain visible in `unmapped` totals.
