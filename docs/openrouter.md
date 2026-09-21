---
summary: "OpenRouter provider: API key credits, spending caps, and daily/weekly/monthly spend."
read_when:
  - Debugging OpenRouter API key usage or spend parsing
  - Updating OpenRouter credits or key-limit display
  - Explaining OpenRouter setup and environment variables
---

# OpenRouter Provider

[OpenRouter](https://openrouter.ai) is a unified API that provides access to multiple AI models from different providers (OpenAI, Anthropic, Google, Meta, and more) through a single endpoint.

## Authentication

OpenRouter uses API key authentication. Get your API key from [OpenRouter Settings](https://openrouter.ai/settings/keys).

### Environment Variable

Set the `OPENROUTER_API_KEY` environment variable:

```bash
export OPENROUTER_API_KEY="sk-or-v1-..."
```

### Settings

You can also configure the API key in CodexBar Settings → Providers → OpenRouter.

A management key in the API key field enables account Activity when using the official OpenRouter API. A separately configured Management API key takes precedence for Activity; the selected API key still supplies quota and balance when OpenRouter permits it.

### CLI config

To monitor multiple OpenRouter accounts, add labeled API keys in the same provider settings. CodexBar fetches each
key independently. Choose the segmented account switcher or stacked account cards under Settings → Display.

```bash
printf '%s' "$OPENROUTER_API_KEY" | codexbar config set-api-key --provider openrouter --stdin
```

A key exported in a terminal is not automatically available to an already-running GUI app. The command above saves
it to CodexBar's resolved config file with owner-only permissions; the app watches that file for changes. The default
is `~/.config/codexbar/config.json`, with legacy `~/.codexbar/config.json` and configured path overrides also supported.

## Data Source

The selected API key supplies current-key data and credit balance when OpenRouter permits that key. Account Activity
uses a separately configured Management API key first, or the primary key when the official Current Key response
identifies it as a management key. Custom API origins cannot promote a key into Activity requests:

OpenRouter documents the [Current Key](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key),
[Credits](https://openrouter.ai/docs/api/api-reference/credits/get-credits), and
[Activity](https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity) contracts separately.

1. **Current Key API** (`/api/v1/key`): Returns the configured key's spending limit, remaining limit, reset window, and key-level usage.
2. **Credits API** (`/api/v1/credits`): Returns total credits purchased and total usage. The balance is calculated as `total_credits - total_usage`. CodexBar always uses the selected API key so a provider-wide management key cannot replace another account’s balance. A rejected request leaves balance unavailable while valid key usage survives.
3. **Activity API** (`/api/v1/activity`, Management API key required): Returns account activity for the last 30 completed UTC days.

Without a Management API key, CodexBar still shows regular API-key quota and key usage, and preserves balance when
OpenRouter accepts the regular key. It leaves a rejected balance and 30-day account spend unavailable instead of
treating either as zero.

Optional requests each have a four-second production deadline, keeping the credits, key, and Activity request stages
within the plugin's total deadline. If the Key API is slow or unavailable,
CodexBar keeps any valid balance and labels the API key limit as unavailable with a safe timeout, HTTP,
or response diagnostic.

Activity history is optional and uses only the fixed official endpoint. The separately configured Management API key wins over a primary management key. Malformed activity, including a combined input/output token total outside the safe integer range, leaves valid credits and key quota available and marks history unavailable.
Reported reasoning counts are retained separately, including when they exceed completion counts. Token totals remain prompt plus completion; reasoning is not added a second time.
Successful HTTP responses that fail JSON parsing or validation are labeled “Response was invalid.” Network failures retain “Request failed” or “Request timed out”; HTTP errors retain their status-specific diagnostic. These optional failures preserve usable data from the other endpoints.

## Display

Successful account Activity adds a compact summary of tokens, requests, and distinct reported models for the last
30 completed UTC days. Detailed model breakdowns and spend stay in Usage & Spend. Reasoning tokens are retained
separately and are not added again to input-plus-output token counts.

The **Usage Dashboard** menu action opens [OpenRouter Activity](https://openrouter.ai/activity) for request and spending history.

The OpenRouter menu card shows:

- **Primary meter**: API key limit usage when the key has a configured limit
- **Spend notes**: Daily, weekly, and monthly API key spend when OpenRouter returns those fields
- **Spend chart**: Day/week/month spend can reuse the shared inline dashboard when enough history is available
- **Balance**: Displayed in the identity section as "Balance: $X.XX" when the credits request succeeds
- **Pay-as-you-go summary**: Uncapped keys show reported monthly key spend, falling back to lifetime key usage or lifetime account usage with an explicit period label. A successful credits request supplies the separate prepaid balance. Turning off the inline cost summary restores the corresponding detail rows; capped keys retain their existing quota meter.

Management-key counters do not produce a key-spend summary: those keys can report zero key usage while the account
has activity. Account credits and available Activity history retain their own scope and reporting period.

Shared usage cards and copied statistics group recognized gateway model identifiers such as `openai/gpt-4o` under public family labels such as “GPT,” with usage attributed to OpenRouter. Raw namespaces and model names are omitted; shared model rankings still require complete eligible history.

The **API key limit** is a spending cap, not your prepaid account balance. Configured positive limits show
“Spending cap, not balance” beneath the amount. Both values remain visible even when the cap exceeds the balance:
a $30 key limit with $30 remaining is **100% left**, independently of a $1.90 account balance from $5 in credits
and $3.10 in account usage. The percentage uses server-reported key remaining first, then spend in the key's reset
window, then cumulative key spend. Used/remaining display preferences do not change these amounts.

Without a configured limit, the detail row says “No limit configured” and no key percentage is shown. Unavailable
key enrichment retains its diagnostic and account balance. CLI text and JSON detail strings use the same limit
label and disclosure. Uncapped reported spend also appears in JSON as `providerCost`; unavailable spend remains absent,
and a reported zero remains zero. CLI text retains the detailed amounts without displaying an artificial zero-dollar budget.
Settings still shows the returned daily, weekly, and monthly key spend when the API key has no configured limit.
The deprecated Current Key API `rate_limit` field is ignored, including malformed values, so it cannot hide valid quota or spend details.

## CLI Usage

With a Management API key, successful Activity history appears in usage text and full terminal cards as a `Last 30 days (UTC)` spend/token summary. Reported spend, BYOK estimates, and mixed totals are labeled accordingly; an empty successful history shows zero. Ordinary usage JSON continues to expose quota, balance, and detail diagnostics without embedding live cost history.

```bash
codexbar --provider openrouter
codexbar -p or  # alias
codexbar --provider openrouter --account Personal
codexbar --provider openrouter --all-accounts --format json --pretty
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `OPENROUTER_API_KEY` | Your OpenRouter API key (required) |
| `OPENROUTER_MANAGEMENT_API_KEY` | Optional Management API key used only for exact 30-day account spend |
| `OPENROUTER_API_URL` | Override the base API URL (optional, defaults to `https://openrouter.ai/api/v1`) |
| `OPENROUTER_HTTP_REFERER` | Optional client referer sent as `HTTP-Referer` header |
| `OPENROUTER_X_TITLE` | Optional client title sent as `X-Title` header (defaults to `CodexBar`) |

## Notes

- Credit values are cached on OpenRouter's side and may be up to 60 seconds stale when a Management API key is configured
- OpenRouter uses a credit-based billing system where you pre-purchase credits
- Rate limits depend on your credit balance (10+ credits = 1000 free model requests/day)
