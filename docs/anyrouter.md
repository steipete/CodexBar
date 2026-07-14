---
summary: "AnyRouter provider: API key credits, balance, and lifetime spend."
read_when:
  - Debugging AnyRouter credit or balance parsing
  - Explaining AnyRouter setup and environment variables
---

# AnyRouter Provider

[AnyRouter](https://anyrouter.dev) is a universal AI model router: one OpenAI-compatible gateway that reaches models
across many upstream providers through a single endpoint, billed from a shared credit balance.

## Authentication

AnyRouter uses API key authentication. Create an inference key on the
[AnyRouter dashboard](https://anyrouter.dev/dashboard/keys). Inference keys are prefixed with `sk-ar-v1-`, which
distinguishes them from upstream provider keys.

### Environment variable

```bash
export ANYROUTER_API_KEY="sk-ar-v1-..."
```

### Settings

You can also store one or more labeled keys in CodexBar Settings → Providers → AnyRouter. Keys are scoped per
organization, so a separate key per environment (dev, staging, prod) can be added and switched between.

### CLI config

```bash
printf '%s' "$ANYROUTER_API_KEY" | codexbar config set-api-key --provider anyrouter --stdin
```

## Data source

The provider reads the credits API (`GET /api/v1/credits`), which is the only endpoint an inference key can reach.
It returns the spendable balance, the lifetime spend, and today's spend:

| Field | Meaning |
|-------|---------|
| `balance` | Total credit available to spend (`monthly_balance` + `topup_balance`) |
| `monthly_balance` | AnyRouter-issued credit: signup bonus, plan grants, referrals. Spent first |
| `topup_balance` | Purchased credit. Spent after monthly credit runs out; never expires |
| `used` | Cumulative lifetime spend |
| `today_cost` | Spend so far today |

AnyRouter's `/api/v1/key` endpoint needs dashboard session auth rather than an inference key, so key-scoped rate
limits are not available to CodexBar today.

## Display

- **Primary meter**: share of granted credit already spent — `used / (used + balance)`.
- **Spend**: lifetime spend against total credit granted.
- **Balance**: shown in the identity section as "Balance: $X.XX".

Because AnyRouter plan credits regenerate monthly, the meter tracks lifetime spend against everything ever granted;
it is a spend indicator, not a countdown to a hard cap.

## CLI usage

```bash
codexbar --provider anyrouter
codexbar -p ar  # alias
```

## Environment variables

| Variable | Description |
|----------|-------------|
| `ANYROUTER_API_KEY` | AnyRouter inference key (required) |
| `ANYROUTER_API_URL` | Override the base API URL (optional, defaults to `https://anyrouter.dev/api/v1`). HTTPS only |
