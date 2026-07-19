---
summary: "Command Code provider notes: cookie authentication and monthly credit parsing."
read_when:
  - Debugging Command Code cookie import or usage parsing
  - Updating Command Code billing or credit display
  - Adjusting Command Code provider UI/menu behavior
---

# Command Code

CodexBar surfaces [Command Code](https://commandcode.ai) monthly USD credits next
to your other AI coding providers.

## Data source

- `https://api.commandcode.ai` billing endpoints, authenticated with the
  signed-in Command Code web session.
- The provider reads monthly credit usage, plan allowance, remaining credits,
  and billing-cycle reset timing when the account data is available.

## Authentication

Command Code support uses browser cookies or a manually pasted cookie header.

1. Sign in to `https://commandcode.ai` in a supported browser.
2. Open Settings -> Providers -> Command Code.
3. Enable Command Code and leave Cookie source on Automatic, or switch to Manual
   and paste a `Cookie:` header/cURL capture from Command Code.

Automatic import looks for better-auth session cookies from `commandcode.ai`
and `www.commandcode.ai`. It tries each detected browser profile in order until
one authenticates, so stale cookies in an earlier browser do not mask a later
active session. If automatic import cannot find a session, use the manual cookie
field.

On Linux, browser import is unavailable. Set `cookieSource` to `manual` and
provide the Command Code `Cookie` header in `cookieHeader`; both `auto` and
`web` CLI source modes then use the billing API.

## Display

- The menu bar item and provider card use the Command Code icon and label.
- The primary row shows monthly credits used/remaining.
- Widgets do not expose Command Code in the provider picker yet.

## Related files

- `Sources/CodexBarCore/Providers/CommandCode/` - descriptor, cookie import,
  billing fetcher, snapshot mapping, and plan catalog.
- `Sources/CodexBar/Providers/CommandCode/` - settings store bridge and
  provider settings UI.
- `Tests/CodexBarTests/CommandCode*Tests.swift` - parser, cookie, settings,
  and icon coverage.
