---
summary: "Command Code provider notes: API key and cookie authentication, usage-window parsing."
read_when:
  - Debugging Command Code cookie import or usage parsing
  - Updating Command Code billing or credit display
  - Adjusting Command Code provider UI/menu behavior
---

# Command Code

CodexBar surfaces [Command Code](https://commandcode.ai) monthly USD credits next
to your other AI coding providers.

## Data source

- `https://api.commandcode.ai` billing endpoints: `/alpha/billing/*` with a
  Command Code API key (the routes the `cmd` CLI uses), or `/internal/billing/*`
  with the signed-in Command Code web session.
- The provider reads 5-hour and weekly rolling limits alongside monthly credit
  usage, plan allowance, remaining credits, and billing-cycle reset timing when
  the account data is available.

## Authentication

Command Code support uses an API key, browser cookies, or a manually pasted cookie header.
Usage source `Auto` uses the selected saved subscription session when active; otherwise it uses a configured API key, or browser cookies when no key is configured.
Select `API key` or `Browser cookies` to pin that source. A rejected key reports an error rather than switching accounts.

### API key

Leave Usage source on **Auto** or select **API key**, then paste a `user_...` key into Settings -> Providers -> Command Code -> API key (stored as `apiKey`
in the [CodexBar config file](configuration.md#location)), or set `COMMAND_CODE_API_KEY`. `cmd login` stores the key in
`~/.commandcode/auth.json`, which CodexBar does not read. This path works on Linux without a cookie.
For the CLI, configure `apiKey` or set `COMMAND_CODE_API_KEY` and run `codexbar usage --provider commandcode --json`.
Use `--source api` to require a key or `--source web` to use cookies explicitly.

### Cookies

1. Sign in to `https://commandcode.ai` in a supported browser.
2. Open Settings -> Providers -> Command Code.
3. Enable Command Code and leave Cookie source on Automatic, or switch to Manual
   and paste a `Cookie:` header/cURL capture from Command Code, or just the session token value.

Bare tokens use the production cookie name `__Secure-commandcode_prod_.session_token`.
Explicit cookie pairs and full headers keep their names and additional cookies, including legacy better-auth names.

Automatic import looks for better-auth session cookies from `commandcode.ai`
and `www.commandcode.ai`. It tries each detected browser profile in order until
one authenticates, so stale cookies in an earlier browser do not mask a later
active session. If automatic import cannot find a session, use the manual cookie
field.

For cookie authentication on Linux, set `cookieSource` to `manual` and provide the
Command Code `Cookie` header in `cookieHeader`. Auto uses it when no API key is configured;
choose `web` to use cookies even when a key is present. Automatic browser import is macOS-only.

### Saved subscription sessions

Choose Cookie source **Manual** to add labeled accounts under **Session tokens**. Paste a bare session token,
a full Cookie header, or a cURL capture. These accounts use the shared account controls and the existing
[private config file](configuration.md#location); full headers retain their additional cookies.

Selecting a saved session uses browser billing even when an API key is configured. Usage source **API key**
keeps saved sessions passive. In the app, switching Cookie source to **Automatic** also keeps saved sessions
passive until one is selected again. A missing or rejected manual session reports an error without trying a
cached or browser account. Removing the final saved account leaves Manual selected; choose Automatic explicitly
to resume browser discovery.

The CLI uses the active saved session unless API source is selected. Explicit `--account`, `--account-index`,
or `--all-accounts` selects saved sessions and uses web billing, including when `--source api` was supplied:

```bash
codexbar usage --provider commandcode --account Personal --json
```

The current Go plan (`individual-go-v1`) includes $10 in monthly credits for a
$1/month subscription plus processing fees, as listed on the [public pricing page](https://commandcode.ai/pricing).
The legacy `individual-go` allowance remains $10.

The credits response reports the monthly grant size (`monthlyCreditsGranted`),
and CodexBar sizes the monthly row from it. The optional subscription lookup
supplies the plan name and the billing-period end, and sizes the grant only
when the credits response omits it. That lookup can time out while credits
remain available. CodexBar keeps the last confirmed plan
in memory, scoped to the credential that produced it. A kept plan is dropped at `currentPeriodEnd`, a day
after the last refresh that confirmed it, when a lookup reports the free tier,
and when a lookup reports a plan this build cannot size. Nothing is written to
disk, so a one-shot `codexbar usage` run starts with an empty memory.

Debug builds accept `COMMANDCODE_API_URL` for synthetic tests against a loopback
origin (`localhost`, `127.0.0.1`, or `::1`). Release builds always use the official
billing endpoint.

## Display

- The menu bar item and provider card use the Command Code icon and label.
- The primary and secondary rows show 5-hour and weekly rolling usage.
- The tertiary row shows monthly credits used/remaining.
- The monthly row is sized from the reported grant, or from the kept plan when
  the credits response omits the grant and the subscription lookup fails. Usage
  always comes from the fresh credits response. After a failed lookup with no
  kept plan, the row keeps its usage but has no reset time; with no grant size at
  all, the row is unavailable rather than shown as untouched. The rolling rows stay
  available either way. Unknown subscription IDs display their raw plan label and the API-reported
  grant/remaining balance; they never hide usage behind a catalog error. Without a reported grant,
  an unknown plan has no monthly percentage. The app also preserves an already-proven depleted monthly
  row while enrichment is unavailable and fresh credits still show depletion.
- Widgets do not expose Command Code in the provider picker yet.

## Related files

- `Sources/CodexBarCore/Providers/CommandCode/` - descriptor, cookie import,
  billing fetcher, snapshot mapping, and plan catalog.
- `Sources/CodexBar/Providers/CommandCode/` - settings store bridge and
  provider settings UI.
- `Tests/CodexBarTests/CommandCode*Tests.swift` - parser, cookie, settings,
  and icon coverage.
