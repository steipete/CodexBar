---
summary: "Raycast provider: unofficial AI credits API, website session cookies, and monthly allowance mapping."
read_when:
  - Configuring Raycast AI credit tracking
  - Debugging Raycast session-cookie or credits parsing
  - Explaining why CodexBar asks for a Raycast website session
---

# Raycast Provider

[Raycast](https://www.raycast.com) plans can include a monthly AI credit allowance. CodexBar uses the amounts reported for the current account. The in-app **Settings → Account** card shows remaining credits and the next renewal date.

The desktop app still uses Bearer `GET /api/v1/ai/credits`. CodexBar uses the **website**
session instead:

```text
GET https://www.raycast.com/frontend_api/current_user/ai_credits
Cookie: __raycast_session=…; csrf_token=…
```

## Authentication

Automatic: CodexBar imports the Chrome session cookie. The session cookie is the host-only `__raycast_session` on
`www.raycast.com` from Account settings. Import uses an exact host match, so other Raycast hosts such as
`backend.raycast.com` are left alone. A parent-domain cookie on `.raycast.com` can still be read, and the account-page
cookie wins when both exist.

Manual: paste that Cookie header into the single **Cookie header** field in Settings. Cookie-only GET is enough; CSRF
is not required for this route. Raycast does not use labeled session-token accounts.

Do not paste the desktop OAuth Bearer. Do not send website cookies to
`backend.raycast.com/api/v1/ai/credits` (401).

Off: disable cookie access and credit requests. Manual headers remain pinned to the selected account and never
fall back to Chrome. Permission failures, rate limits, service errors, and malformed payloads stop retries without
rejecting the session.

## Implementation

The shared plugin host owns declared-domain Chrome import and the domain-scoped cookie cache. The bundled
`raycast` plugin owns session candidate iteration, rejection, the credits GET, and snapshot mapping:

1. Iterate `ctx.browser.sessions("www.raycast.com")`, keeping only `__raycast_session` and optional `csrf_token`.
   Reject candidates without a session or with HTTP 401 and try the next candidate in the same refresh.
2. GET `https://www.raycast.com/frontend_api/current_user/ai_credits` with site `Origin` / `Referer` and the resolved
   Cookie header.
3. Map a positive total into one primary Credits meter. The remaining balance is the meter's `resetDescription`. Left and Total rows are kept only when that meter is absent.

## Data shown

| Field | Display |
| --- | --- |
| `remaining_balance_credits`, `total_balance_credits` | One **Credits** meter when the total is above zero. The title keeps the percent (`Credits 67% left`, or `33% used` when usage bars show used). The line under the bar is the remaining balance, `337.38 / 500 credits left`. |
| `next_credits_at` | The meter's standard reset line (`Resets in 25d 4h`, or an absolute `Resets …`). When there is no meter, the same date is the card note `Renews: …`. |
| `funding_subscription.tier` | Header plan label (`pro` → Pro, `pro_plus` → Pro+, `max` → Max) |

When both amounts are present and the total is above zero, the primary meter is percent used of the reported total. The balance string is remaining over that total, so a rollover balance such as `750 / 500 credits left` stays visible and the percent stays at 0% used. Left and Total are not a second Credits section on that card. A zero total leaves the meter off and keeps those rows.

Remaining can exceed the current grant when unused monthly credits roll over. CodexBar still uses the reported total as
the denominator and does not invent extra usage.

Top-up packages and the Show details breakdown (`GET /api/v1/ai/credits/details`) are not fetched yet.

## Limitations

- The website credits route is unofficial and can change without notice.
- Automatic import needs a signed-in www.raycast.com session (`__raycast_session`) in Chrome.
- BYOK, Bring Your Own Subscription, and local models do not count against these credits and are not shown here.
