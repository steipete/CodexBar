---
summary: "Devin provider auth, quota endpoint, and setup."
read_when:
  - Adding or modifying the Devin provider
  - Debugging Devin localStorage import or quota parsing
  - Explaining Devin setup
---

# Devin Provider

The Devin provider tracks included daily and weekly usage quotas from
[app.devin.ai](https://app.devin.ai).

## Setup

1. Sign in to Devin in Google Chrome.
2. Open the organization Usage & Limits page once.
3. Enable **Devin** in **Settings → Providers**.

Automatic mode reads only the Devin session and organization metadata from Chrome localStorage. It does not scan other
browsers. CodexBar sends the session token only to `https://app.devin.ai`.

## Manual Auth

Set **Auth source** to **Manual**, then paste either the bare token or the full `Authorization: Bearer ...` header value
from an app.devin.ai API request. The optional organization field accepts a slug, an internal `org_...` ID, or the full
organization URL.

Environment overrides:

- `DEVIN_BEARER_TOKEN` or `DEVIN_AUTHORIZATION`
- `DEVIN_ORGANIZATION` or `DEVIN_ORG`

## Data Source

CodexBar requests:

```text
GET https://app.devin.ai/api/<internal-org-id>/billing/quota/usage
```

The response supplies daily and weekly usage percentages plus reset timestamps. If Devin changes or expires the browser
session, sign in again and refresh CodexBar.
