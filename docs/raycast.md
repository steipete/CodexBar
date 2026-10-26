---
summary: "Raycast provider: unofficial AI credits API, website session cookies, and monthly allowance mapping."
read_when:
  - Configuring Raycast AI credit tracking
  - Debugging Raycast session-cookie or credits parsing
  - Explaining why CodexBar asks for a Raycast website session
---

# Raycast Provider

[Raycast](https://www.raycast.com) plans can include a monthly AI credit allowance. CodexBar uses the amounts reported for the current account. The in-app **Settings → Account** card shows remaining credits and the next renewal date.

CodexBar reads the unofficial website credits API using a **website session**:

```text
GET https://www.raycast.com/frontend_api/current_user/ai_credits
Cookie: __raycast_session=…; csrf_token=…
```

## Authentication

In Settings → Providers → Raycast, choose a cookie source:

- **Automatic:** sign in to `www.raycast.com` in a supported browser. CodexBar follows the shared browser order and imports the host-only `__raycast_session` from Account settings, preferring it over a same-name `.raycast.com` cookie. Sibling hosts such as `backend.raycast.com` are excluded.
- **Manual:** paste a website Cookie header into **Cookie header**. It stays pinned to that account with no browser fallback. CSRF is optional for this GET; labeled session-token accounts are unsupported.
- **Off:** disables cookie access and credit requests.

The desktop app uses Bearer `GET /api/v1/ai/credits`. Do not paste its OAuth Bearer into CodexBar or send website cookies to `backend.raycast.com/api/v1/ai/credits`; that combination returns 401.

Automatic mode tries the next session when a candidate lacks `__raycast_session` or returns HTTP 401. Permission failures, rate limits, service errors, and malformed payloads stop retries without rejecting the session.

## Request contract

The plugin uses `ctx.browser.sessions("www.raycast.com")`, keeping only `__raycast_session` and optional `csrf_token`. The host owns browser import and the domain-scoped cache; the plugin owns candidate rejection and the GET, including site `Origin` / `Referer` headers. A positive total maps to one primary meter with the remaining balance in `resetDescription`.

Settings omits the Version row because this provider reads the website API and does not detect the desktop app version.

## Data shown

| Field | Display |
| --- | --- |
| `remaining_balance_credits`, `total_balance_credits` | One **Credits** meter when the total is above zero. The title keeps the percent (`Credits 67% left`, or `33% used` when usage bars show used). The line under the bar is the remaining balance, `337.38 / 500 credits left`. |
| `next_credits_at` | The meter's standard reset line (`Resets in 25d 4h`, or an absolute `Resets …`). When there is no meter, the same date is the card note `Renews: …`. |
| `funding_subscription.tier` | Header plan label (`pro` → Pro, `pro_plus` → Pro+, `max` → Max) |

The meter requires both amounts and a positive total. Rollover balances can exceed the grant: `750 / 500 credits left` remains visible at 0% used, using the reported total as denominator. **Left** and **Total** rows appear only when there is no meter, including a zero total.

Top-up packages and the Show details breakdown (`GET /api/v1/ai/credits/details`) are not fetched yet.

## Limitations

- The website credits route is unofficial and can change without notice.
- BYOK, Bring Your Own Subscription, and local models do not count against these credits and are not shown here.
