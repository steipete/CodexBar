---
summary: "Venice API balance and optional browser subscription-credit details."
read_when:
  - Updating Venice authentication or credit presentation
---

# Venice

Auto and API use the configured Venice API key. Select **Web** to read subscription credits from a signed-in
Venice browser session. Web imports Chrome cookies by default; **Manual** accepts a Venice Cookie header.
**Off** prevents cookie import and web requests, including when a manual header remains saved.

Saved API accounts remain stored but do not own implicit Web requests. Switching back to Auto or API restores
the selected API account. Explicit CLI account selection (`--account`, `--account-index`, or `--all-accounts`)
uses that API account even when Web is configured.

The web source requests `https://outerface.venice.ai/api/user/session` with only Venice session cookies and
reads the returned token's subscription-credit claims. It shows available subscription and total credits,
spending this cycle compared with the monthly refill, the bank cap, and the next refill date when reported.
These private dashboard fields may change.

Monthly refill is not a spending limit: banked credits can remain after spending exceeds one refill. Web data
therefore appears as credit details, without an exhausted quota percentage or an inferred subscription-renewal
date. Identity from API keys is never attached to browser credit data. Missing or expired sessions ask for sign-in;
a rejected Chrome profile can fall through to another signed-in profile.
