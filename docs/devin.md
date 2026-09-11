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

## Linux CLI

Automatic Chrome session import is macOS-only. On Linux, configure manual auth in
`~/.config/codexbar/config.json` (or your existing legacy config):

```json
{
  "version": 1,
  "providers": [{
    "id": "devin",
    "cookieSource": "manual",
    "cookieHeader": "Bearer YOUR_DEVIN_TOKEN",
    "workspaceID": "org_YOUR_ORGANIZATION"
  }]
}
```

Run `codexbar usage --provider devin`. You can omit `cookieHeader` when supplying
`DEVIN_BEARER_TOKEN` or `DEVIN_AUTHORIZATION`, but keep `cookieSource` set to `manual`.
The organization environment overrides also apply. Environment tokens take precedence
without enabling automatic auth; an empty override does not fall back to the configured token.

## Data Source

CodexBar requests:

```text
GET https://app.devin.ai/api/<internal-org-id>/billing/quota/usage
```

The response supplies daily and weekly usage percentages plus reset timestamps. If Devin changes or expires the browser
session, sign in again and refresh CodexBar.
