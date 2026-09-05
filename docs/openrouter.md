---
summary: "OpenRouter provider: API key credits, rate limits, and daily/weekly/monthly spend."
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

### CLI config

To monitor multiple OpenRouter accounts, add labeled API keys in the same provider settings. CodexBar fetches each
key independently. Choose the segmented account switcher or stacked account cards under Settings → Display.

```bash
printf '%s' "$OPENROUTER_API_KEY" | codexbar config set-api-key --provider openrouter --stdin
```

## Data Source

The OpenRouter provider fetches usage data from two API endpoints:

1. **Credits API** (`/api/v1/credits`): Returns total credits purchased and total usage. The balance is calculated as `total_credits - total_usage`.

2. **Key API** (`/api/v1/key`): Returns rate limit information plus current daily, weekly, and monthly spend for your API key.

The Key API is optional enrichment with a one-second production deadline. If it is slow or unavailable, CodexBar still
shows the credits balance and labels the API key limit as unavailable with a safe timeout, HTTP, or response diagnostic.

## Display

The **Usage Dashboard** menu action opens [OpenRouter Activity](https://openrouter.ai/activity) for request and spending history.

The OpenRouter menu card shows:

- **Primary meter**: API key limit usage when the key has a configured limit
- **Spend notes**: Daily, weekly, and monthly API key spend when OpenRouter returns those fields
- **Spend chart**: Day/week/month spend can reuse the shared inline dashboard when enough history is available
- **Balance**: Displayed in the identity section as "Balance: $X.XX"

The **API key limit** is a spending cap, not your prepaid account balance. Configured positive limits show
“Spending cap, not balance” beneath the amount. Both values remain visible even when the cap exceeds the balance:
a $30 key limit with $30 remaining is **100% left**, independently of a $1.90 account balance from $5 in credits
and $3.10 in account usage. The percentage uses server-reported key remaining first, then spend in the key's reset
window, then cumulative key spend. Used/remaining display preferences do not change these amounts.

Without a configured limit, the detail row says “No limit configured” and no key percentage is shown. Unavailable
key enrichment retains its diagnostic and account balance. CLI text and JSON detail strings use the same limit
label and disclosure; the JSON structure is unchanged.

## CLI Usage

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
| `OPENROUTER_API_URL` | Override the base API URL (optional, defaults to `https://openrouter.ai/api/v1`) |
| `OPENROUTER_HTTP_REFERER` | Optional client referer sent as `HTTP-Referer` header |
| `OPENROUTER_X_TITLE` | Optional client title sent as `X-Title` header (defaults to `CodexBar`) |

## Notes

- Credit values are cached on OpenRouter's side and may be up to 60 seconds stale
- OpenRouter uses a credit-based billing system where you pre-purchase credits
- Rate limits depend on your credit balance (10+ credits = 1000 free model requests/day)
