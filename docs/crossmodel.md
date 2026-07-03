---
summary: "CrossModel provider: API key wallet balance and daily/weekly/monthly spend."
read_when:
  - Debugging CrossModel API key usage or spend parsing
  - Updating CrossModel balance or spend display
  - Explaining CrossModel setup and environment variables
---

# CrossModel Provider

[CrossModel](https://crossmodel.ai) is a multi-provider, OpenAI- and Anthropic-compatible API aggregation platform. You call one API and CrossModel routes the request to the right upstream provider, billing a prepaid wallet.

## Authentication

CrossModel uses API key authentication. Create a key in the [CrossModel console](https://crossmodel.ai/console/api-keys). Keys start with `cm-`.

### Environment Variable

Set the `CROSSMODEL_API_KEY` environment variable:

```bash
export CROSSMODEL_API_KEY="cm-..."
```

### Settings

You can also configure the API key in CodexBar Settings → Providers → CrossModel.

### CLI config

```bash
printf '%s' "$CROSSMODEL_API_KEY" | codexbar config set-api-key --provider crossmodel --stdin
```

## Data Source

The CrossModel provider fetches data from two read-only API endpoints:

1. **Credits API** (`/v1/credits`): Returns the wallet balance (`balance_micro`), currency, and any in-flight holds (`uncollected_micro`). All amounts are integer micro units (1 major currency unit = 1,000,000 micro).

2. **Usage API** (`/v1/usage`): Returns currency plus spend, token, and request counts for the current UTC day, ISO week, and calendar month. CodexBar only displays usage spend when `/usage` currency matches `/credits` currency.

## Display

The CrossModel menu card shows:

- **Balance**: Displayed in the CrossModel menu section and (optionally) in the menu bar using the API currency
- **Spend notes**: Today / this week / this month spend
- **Spend chart**: Day/week/month spend via the shared inline dashboard

## CLI Usage

```bash
codexbar --provider crossmodel
codexbar -p cm  # alias
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CROSSMODEL_API_KEY` | Your CrossModel API key (required) |
| `CROSSMODEL_API_URL` | Override the base API URL (optional, defaults to `https://api.crossmodel.ai/v1`; loopback HTTP is allowed for local testing) |

## Notes

- Usage values are cached on CrossModel's side and may be up to 60 seconds stale.
- CrossModel uses a prepaid wallet; there is no per-key spending limit, so no quota meter is shown.
- The balance call is required; the usage call is best-effort, deadline-bounded, and will not block the balance if it is slow, unavailable, or returns a mismatched currency.
