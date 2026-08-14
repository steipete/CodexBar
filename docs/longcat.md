---
summary: "LongCat provider cookie sources, quota requests, and snapshot mapping."
read_when:
  - Debugging LongCat usage or stale zero quotas
  - Updating LongCat cookie handling or web requests
  - Adjusting LongCat quota or fuel-pack mapping
---

# LongCat provider

LongCat reads quota data from an authenticated `longcat.chat` web session. It does not require an API key.

## Data sources

- A manual cookie header can be entered in Settings → Providers → LongCat or supplied through
  `LONGCAT_MANUAL_COOKIE`.
- Automatic mode can import supported browser cookies during a user-initiated refresh.

## Request sequence

1. `GET /api/v1/user-current` is required and validates the session while providing the account name.
2. `POST /api/pay/quota/metering/token-packs/summary` provides the primary live token-pack quota. This probe is
   best-effort because some browser cookies are scoped to other API paths.
3. `GET /api/lc-platform/v1/tokenUsage` is required only when the summary has no active lot with a positive total.
4. `GET /api/lc-platform/v1/pending-fuel-packages` is best-effort and runs in both primary-quota paths.

The legacy `tokenUsage` response can report stale zeros for token-pack accounts, so it is only a fallback (#2670).

## Snapshot mapping

An active `currentLot` maps `totalToken` to the primary total and `consumedToken` to primary used tokens. When no
usable lot exists, the legacy token-usage aggregate supplies total, used, and remaining quota. Pending fuel packages
are summed into the secondary window, with their nearest expiry used as its reset time.
