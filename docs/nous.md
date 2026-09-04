---
summary: "Nous Portal provider: Hermes Agent OAuth token reuse, account endpoint parsing, and credit display."
read_when:
  - Debugging Nous Portal credit or subscription parsing
  - Explaining why CodexBar asks to run `hermes` to refresh the token
  - Updating Nous Portal setup or environment variables
---

# Nous Portal Provider

[Nous Portal](https://portal.nousresearch.com) is Nous Research's subscription and credit portal for the Hermes
inference API. Plans grant a monthly credit budget that resets each billing cycle; purchased credits top up the
balance on top of that grant.

## Authentication

Nous Portal only exposes its account and billing endpoints to the OAuth access token minted by the Hermes Agent
device-code login. CodexBar does not run its own login and does not store any Nous secret:

1. Sign in once with Hermes Agent (`hermes` and choose Nous Portal, or `hermes auth add nous`).
2. Hermes writes the token to `~/.hermes/auth.json` (and a cross-profile copy to `~/.hermes/shared/nous_auth.json`).
3. CodexBar reads the access token from those files on every refresh.

Overrides:

- `HERMES_HOME`: directory holding `auth.json` when Hermes runs from a custom root or profile. It is exclusive: when
  set, `~/.hermes` is never consulted, so a missing or expired custom profile reports an error rather than silently
  using another profile's login.
- `NOUS_PORTAL_ACCESS_TOKEN`: use this token instead of the Hermes files.
- `NOUS_PORTAL_BASE_URL` / `HERMES_PORTAL_BASE_URL`: point at a preview portal deployment. HTTPS only; plain HTTP
  is refused for every host, loopback included, and the default portal is used instead.

### Where the token is sent

The bearer token only ever goes to one origin, resolved in this order:

1. An explicit `NOUS_PORTAL_BASE_URL` / `HERMES_PORTAL_BASE_URL` override (HTTPS only, set by you).
2. The `portal_base_url` stored by Hermes, but only when its host is `nousresearch.com` or a subdomain.
3. `https://portal.nousresearch.com`.

A stored host outside `nousresearch.com` is ignored, logged as a warning, and reported in the verbose trace as
`rejectedStoredHost=<host>`; the request then goes to the default portal. Expired tokens, whether from the auth file or
from `NOUS_PORTAL_ACCESS_TOKEN`, are rejected before any request is made.

### Why CodexBar never refreshes the token

Nous access tokens live for about an hour. The refresh token is single-use: the portal rotates it on every refresh and
revokes the entire session when it sees an old one replayed. A second client refreshing behind Hermes's back would
therefore log Hermes out. CodexBar only reads the current access token and, once it has expired, shows
"run `hermes` so Hermes Agent refreshes it". Any Hermes command (or a running Hermes gateway) renews the token.

## Data Source

One request per refresh: `GET {portal}/api/oauth/account` with the bearer token.

| Field | Display |
| --- | --- |
| `subscription.monthly_credits`, `subscription.credits_remaining` | Primary meter "Monthly credits" as percent used |
| `subscription.current_period_end` | Meter reset time and renewal date |
| `subscription.plan` | Plan row (plan name only, e.g. `Ultra`) |
| `subscription.rollover_credits` | Subscription detail row when non-zero |
| `purchased_credits_remaining` | Credits snapshot and the "Top-up credits" row in the Credits section |
| `paid_service_access.total_usable_credits` | Credits detail row |
| `user.email`, `organisation.name` | Identity (siloed to this provider) |

Money fields are accepted both as JSON numbers and as decimal strings. A Free tier with no monthly grant shows no
meter and only the purchased balance.

## API keys

Nous Portal API keys authenticate only the inference API (`/v1/chat/completions`, `/v1/completions`). The portal's
account and billing endpoints accept the OAuth access token only, so CodexBar cannot show credits from an API key.
Use the Hermes Agent login.

## CLI

```bash
codexbar usage --provider nous
```

Aliases: `nous-portal`, `hermes`. Source modes: `auto`, `api`.
