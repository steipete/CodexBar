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

## Data Source

The OpenRouter provider fetches usage data from two API endpoints:

1. **Credits API** (`/api/v1/credits`): Returns total credits purchased and total usage. The balance is calculated as `total_credits - total_usage`.

2. **Key API** (`/api/v1/key`): Returns rate limit information for your API key.

## Display

The OpenRouter menu card shows:

- **Primary meter**: Credit usage percentage (how much of your purchased credits have been used)
- **Balance**: Displayed in the identity section as "Balance: $X.XX"

## CLI Usage

```bash
codexbar --provider openrouter
codexbar -p or  # alias
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
