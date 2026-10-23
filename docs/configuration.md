---
summary: "CodexBar config file layout for CLI + app settings."
read_when:
  - "Editing the CodexBar config file or moving settings off Keychain."
  - "Adding new provider settings fields or defaults."
  - "Explaining CLI/app configuration and security."
---

# Configuration

The app's **Help → CodexBar Help** command opens the [README](https://github.com/steipete/CodexBar/blob/main/README.md), including setup instructions and links to provider documentation.
**Settings → About → Website** opens the project website at [codexbar.app](https://codexbar.app).

The app and CLI share one JSON file for API keys, manual cookie headers, source selection, provider ordering, and token accounts. The running app detects external edits, atomic replacements, and restored older contents, including during watcher startup and change callbacks. App writes update the baseline without being treated as external edits.
Keychain holds runtime cookie caches, browser Safe Storage access, and provider OAuth/device-flow credentials where required.
App settings writes are coalesced. Normal quit finishes any pending configuration write in the background before exiting, including an edit made just before quitting. A failed final write is logged and does not prevent quitting.

## Location
- `CODEXBAR_CONFIG=/path/to/config.json` when set.
- `$XDG_CONFIG_HOME/codexbar/config.json` when `XDG_CONFIG_HOME` is set to an absolute path. Relative values are
  ignored.
- `~/.config/codexbar/config.json` by default for new installs.
- `~/.codexbar/config.json` for existing legacy installs when no XDG config exists.
- The directory is created if missing.
- Writes on macOS and Linux create a `0600` file inside a private `0700` staging directory beside the destination before writing any bytes, then sync and atomically replace the destination. Failed writes preserve the previous file and remove staging.
- Current app and CLI writers coordinate through a persistent, empty `config.json.lock` beside the config. CLI token refresh compares the saved credential and publishes its replacement under this lock, skipping the update if another writer holds it. Older versions and external editors do not participate in this advisory lock.

A missing, zero-byte, or JSON-whitespace-only file (spaces, tabs, carriage returns, and line feeds) means no
configuration. Reads use defaults without creating or rewriting the file; the next settings save writes valid JSON.
If the running app sees a blank file, it retains its in-memory settings just as it does when the file is removed.
Non-empty malformed JSON still reports a decode error in the CLI, blocks usage and config edits, and is not
replaced by `loadOrCreateDefault()`.

## Root shape
```json
{
  "version": 1,
  "hooks": null,
  "providers": [
    {
      "id": "codex",
      "enabled": true,
      "source": "auto",
      "cookieSource": "auto",
      "cookieHeader": null,
      "apiKey": null,
      "enterpriseHost": null,
      "region": null,
      "workspaceID": null,
      "tokenAccounts": null
    }
  ]
}
```

`shareUsageWithCLI` (optional boolean, default off) lets `codexbar usage` fall back to the app's cached numbers in SSH
sessions; see [CLI](cli.md#ssh-sessions-macos).

## External event hooks

Hooks are local, explicit opt-in automation. Configure them in Settings > Hooks or in this local config file; no
HTTP or remote-config endpoint can create or enable hook rules. The top-level `hooks.enabled` switch defaults to
`false`, and each rule also has its own `enabled` switch. The editor shows thresholds as percentages; example
values and command paths appear only as prompts in empty fields.

```json
{
  "hooks": {
    "enabled": true,
    "events": [
      {
        "id": "quota-alert",
        "enabled": true,
        "event": "quota_low",
        "provider": "codex",
        "threshold": 0.9,
        "executable": "/usr/local/bin/quota-alert",
        "arguments": ["--message", "Codex quota is low", ""],
        "timeoutSeconds": 10
      }
    ]
  }
}
```

Commands run as direct executable invocations, never through a shell. `executable` must be an absolute path,
`arguments` preserves exact argument boundaries (including spaces and empty arguments), and `timeoutSeconds` must be
between `0.1` and `300`. Hook processes receive only a small allowlist of general environment variables plus the
event's `CODEXBAR_*` variables; CodexBar provider keys and tokens are not inherited. The same event is also encoded as
JSON on stdin. Only configure executables you trust.

Installed user plugins can be selected by manifest ID (or by an any-provider rule). Their successful, current app
refreshes support `usage_updated`, `quota_low`, `quota_reached`, and `quota_reset` through the same command and payload
contract. See [plugin hooks](plugins.md#external-hooks) for window semantics and lifecycle behavior.

Events:

- `quota_low`: a quota lane crosses the rule's `threshold` upward. Thresholds are usage fractions greater than `0`
  and at most `1`;
  rules without a threshold use the provider's configured warning thresholds.
- `quota_reached`: the primary session quota crosses into depletion.
- `quota_reset`: a confirmed session or weekly reset occurs.
- `usage_updated`: the macOS app published a successful, current provider refresh, or `hooks watch` completed a
  successful poll. It can fire when values are unchanged. `usagePercent`, `windowMinutes`, and `resetAt`
  describe the positional primary window; `secondaryUsagePercent`, `secondaryWindowMinutes`, and
  `secondaryResetAt` describe the positional secondary window. Synthetic placeholder windows are omitted.
- `provider_unavailable`: a provider status changes to a minor, major, or critical outage.
- `provider_recovered`: that tracked outage returns to normal.
- `refresh_failed`: a provider refresh fails; `CODEXBAR_STATUS` is a coarse category such as `timeout`, `offline`,
  `network_error`, `auth_required`, `cancelled`, or `error`.

`usage_updated`, `provider_unavailable`, and `refresh_failed` allow the first matching attempt immediately,
then drop further attempts for the same provider/account/window for 600 seconds. Failed command attempts consume
that interval; unmatched rules do not. There is no queued latest value or trailing delivery. Restarting resets
the in-memory limiter. Quota and recovery events use their transition detectors instead. Hook failures are
contained and never block app provider refresh. `hooks watch` reports only events whose command execution was
attempted, including failed commands, rather than suppressed candidates.

Payload environment variables are `CODEXBAR_EVENT`, `CODEXBAR_PROVIDER`, `CODEXBAR_TIMESTAMP`, and, when available,
`CODEXBAR_ACCOUNT`, `CODEXBAR_WINDOW`, `CODEXBAR_USAGE_PERCENT`, `CODEXBAR_USED`, `CODEXBAR_LIMIT`,
`CODEXBAR_WINDOW_MINUTES`, `CODEXBAR_RESET_AT`, `CODEXBAR_SECONDARY_USAGE_PERCENT`,
`CODEXBAR_SECONDARY_WINDOW_MINUTES`, `CODEXBAR_SECONDARY_RESET_AT`, and `CODEXBAR_STATUS`. Enabling Hide personal info
omits `CODEXBAR_ACCOUNT` and the matching JSON field.

The stdin JSON uses the same camel-case field names without the `CODEXBAR_` prefix. Dates are UTC ISO 8601 strings,
usage percentages are `0...1` fractions, unavailable optional fields are omitted rather than encoded as `null`, and
keys are emitted in sorted order. A `quota_reached` payload is exactly shaped like this (the timestamps vary):

```json
{"event":"quota_reached","provider":"claude","resetAt":"2023-11-14T22:13:20Z","timestamp":"2023-11-14T22:15:00Z","usagePercent":0.42,"window":"session"}
```

The v1 field names and meanings are compatibility-stable. Hook consumers should ignore unknown fields so CodexBar can
add optional observability data without breaking existing commands.

Safety limits: at most 32 rules, 32 arguments per rule, 4 KiB per executable or argument string, 32 KiB per command,
and 4 KiB per event payload. Configurations beyond these limits fail closed and do not execute.

## Provider fields
All provider fields are optional unless noted.

- `id` (required): provider identifier.
- `enabled`: enable/disable provider (defaults to provider default).
- `source`: preferred source mode.
  - `auto|web|cli|oauth|api`
  - `auto` uses [provider-specific fallback order](providers.md#fetch-strategies-current).
  - `api` uses the provider's API-backed mode; only some providers consume the `apiKey` field.
- `apiKey`: raw API token for providers that support config-backed direct API usage.
- `enterpriseHost`: provider-specific API host/base URL override. Used by Azure OpenAI, Copilot, LLM Proxy, LiteLLM,
  ClawRouter, sub2api, and Wayfinder.
- `cookieSource`: cookie selection policy.
  - `auto` (browser import), `manual` (use `cookieHeader`), `off` (disable cookies)
- `cookieHeader`: raw cookie header value (e.g. `key=value; other=...`).
- `region`: provider-specific region (e.g. `zai`, `minimax`). Kimi accepts `china` (default, `kimi.com`) or `international` (`kimi.ai`); see [Kimi setup](kimi.md). This selects API, web, cookie discovery, and dashboard hosts. Automatic CLI credential reuse is limited to China because the credential file has no issuing-host metadata.
- `workspaceID`: provider-specific workspace/deployment/project ID (e.g. Azure OpenAI deployment, OpenAI API project,
  `opencode`, Notion space).
- `modelRateLimits`: optional per-model organization rate limits for the provider-level key (`apiKey` or environment
  key), currently used by OpenAI Live Usage. Token accounts never inherit these limits.
  Each row has `model`, positive integer `tokensPerMinute`, and optional positive integer `requestsPerMinute`.
  Model IDs are trimmed; empty IDs and non-positive TPM rows are dropped, non-positive RPM becomes absent,
  and the last valid row for a duplicate ID wins. Empty arrays are omitted when encoding. Only these manual limits drive
  organization utilization; API project caps are separate context. Exact IDs match first, then the longest model
  ID followed by a hyphen (covering dated snapshots).
  Example: `"modelRateLimits": [{"model": "gpt-5", "tokensPerMinute": 40000000, "requestsPerMinute": 15000}]`.
- `tokenAccounts`: multi-account tokens for providers in `TokenAccountSupportCatalog`.
- `claudeSwapEnabled`: allow the Claude provider to read account usage from claude-swap.
- `claudeSwapExecutablePath`: path to the `cswap` executable, or to `tcr` when `claudeSwapSource` is `"tcr"`.
- `claudeSwapSource`: `"claude-swap"` (default) or `"tcr"`; selects the list command (`cswap --list --json` or
  `tcr list --json`), the card label and the `<source>:<slot>` identity. Machine-local like the executable path.
- `claudeSwapShowSingleAccount`: prefer a claude-swap card when exactly one account is available. Defaults to
  `false`; multiple claude-swap accounts retain their existing precedence.

## Manual cookies
Use manual cookies when automatic browser import is unavailable, disabled, or too noisy for your setup.
The app and CLI both read the same resolved config file, so a manual cookie saved in the UI is also used by
`codexbar`, and a cookie written by tooling is shown in the app after reload.

`cookieHeader` expects the HTTP `Cookie:` request header value for the provider origin, not a raw Netscape cookie
export. In browser DevTools, open the Network tab, select a request for the provider site, and copy the request
header named `Cookie`. You can paste either the full `Cookie: name=value; other=value` string or just
`name=value; other=value`.

If you have a Netscape export, convert each non-comment row to `name=value` and join values with `; `. Do not paste
the raw `# Netscape HTTP Cookie File` text into `cookieHeader`.

Example placeholder config:

```json
{
  "version": 1,
  "providers": [
    {
      "id": "claude",
      "enabled": true,
      "cookieSource": "manual",
      "cookieHeader": "sessionKey=<REDACTED>"
    }
  ]
}
```

Validate after editing:

```bash
codexbar config validate
```

Replace the placeholder with your own cookie before fetching usage with `codexbar usage --provider claude`.
For another provider, use its registered [ID](provider-ids.md) and the cookie format in its [setup guide](providers.md).

## CLI configuration

```bash
codexbar config providers
codexbar config enable --provider grok
codexbar config disable --provider cursor
printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
```

Use the same `set-api-key --provider <id> --stdin` command with these provider/key pairs:

| Provider ID | Key environment variable | Additional configuration |
| --- | --- | --- |
| `openai` | `OPENAI_ADMIN_KEY` | `workspaceID` maps to `OPENAI_PROJECT_ID` for Admin API usage; applies to the configured key, not selected token accounts. |
| `groq` | `GROQ_API_KEY` | See [Groq](groq.md). |
| `llmproxy` | `LLM_PROXY_API_KEY` | Required base URL: `enterpriseHost` or `LLM_PROXY_BASE_URL`. |
| `litellm` | `LITELLM_API_KEY` | Required base URL: `enterpriseHost` or `LITELLM_BASE_URL`. |
| `clawrouter` | `CLAWROUTER_API_KEY` | Defaults to the hosted service; override with `enterpriseHost` or `CLAWROUTER_BASE_URL`. |
| `sub2api` | `SUB2API_API_KEY` | Required self-hosted base URL: `enterpriseHost` or `SUB2API_BASE_URL`. Use labeled token accounts for multiple group keys. |
| `aiand` | `AIAND_API_KEY` | See [ai&](aiand.md). |
| `xai` | `XAI_MANAGEMENT_API_KEY` | See [xAI](xai.md). |

See [CLI configuration](cli-configuration.md) for scripting examples and output formats.

Manual cookies are secrets. Keep the CodexBar config file private, leave its permissions at `0600`, never commit it,
and never paste real cookie values or readable DevTools screenshots into public issues.

### tokenAccounts
```json
{
  "version": 1,
  "activeIndex": 0,
  "accounts": [
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "label": "user@example.com",
      "token": "sk-...",
      "addedAt": 1735123456,
      "lastUsed": 1735220000
    }
  ]
}
```

Each OpenAI token account can store `tokenAccounts.accounts[].modelRateLimits`: omitted means not set; `[]` means
explicitly no limits (kept so clears sync and older CodexBar versions cannot erase limits during sync). Rows use
the same validation as provider-level `modelRateLimits`. Limits belong only to that account; there is no
inheritance. Settings edits the selected account's limits, and switching accounts switches the list.

```json
{
  "id": "openai",
  "modelRateLimits": [{"model": "gpt-5", "tokensPerMinute": 40000000}],
  "tokenAccounts": {
    "version": 1,
    "activeIndex": 0,
    "accounts": [{
      "id": "00000000-0000-0000-0000-000000000001",
      "label": "Other organization",
      "token": "<OPENAI_ADMIN_KEY>",
      "addedAt": 1735123456,
      "modelRateLimits": [{"model": "gpt-5", "tokensPerMinute": 80000000}]
    }]
  }
}
```

z.ai team accounts also use `usageScope`, `organizationId`, and `workspaceID`; see [z.ai](zai.md).

## Provider IDs

See the [generated provider ID list](provider-ids.md), sourced from `UsageProvider` in enum order.

## Ordering
The order of `providers` controls display/order in the app and CLI. Reorder the array to change ordering.

## iCloud sync
The three sync sub-options are disabled while the main sync switch is off, iCloud is unavailable, or a newer app version is required. Their saved choices are retained when sync is turned off and restored when it is enabled again.

Opt-in (Settings → iCloud Sync, off by default; requires a signed release build and an iCloud account). When enabled, CodexBar syncs across the user's Macs via CloudKit (private database, container `iCloud.com.steipete.codexbar`):

- **Provider configuration** — portable fields of each provider entry (enabled intent, extras, region, workspace, quota-warning overrides, ordering-relevant metadata). Secrets (`apiKey`, `secretKey`, `cookieHeader`, `tokenAccounts`) sync only when "Include API keys, cookies, and tokens" is on, and travel exclusively in CloudKit `encryptedValues` (end-to-end encrypted; readable only on the user's devices).
- **A curated preferences subset** — notification/threshold/display settings.
- **Usage snapshots** — per-device current usage per account, so other Macs can show last-known data ("via <Mac> · 1h ago") and accounts discovered on other Macs.

With Usage snapshots and Show accounts from other Macs enabled, an enabled provider without local usage can also use the freshest fleet fallback in separate, current-selection, highest-usage, and stacked menu bar icons. The menu labels its source and age; accessibility help includes the source Mac and capture time, respecting Hide personal info. Local snapshots remain authoritative. Remote usage does not enable local credential-dependent fetches or populate local costs, pace, credits, or account labels. Highest usage compares the same presentation snapshots without enabling local fetches. Fleet refreshes preserve an open menu's provider switcher until the menu is closed and reopened.

The **Macs** list offers **Remove** for other devices, including stale duplicates left after a reinstall. Removal deletes that device record and its cached usage snapshots from iCloud; it leaves shared settings, credentials, and this Mac intact. Sync must be enabled and available. Failed removals remain visible and report a sync error. A Mac still running CodexBar with sync enabled can publish its records again: if a save finds that its previous record was deleted, it drops the stale server version and retries with a fresh record. If that fresh record is also reported missing, CodexBar surfaces the error instead of retrying indefinitely.

Automatic reception of changes requires a release signed with the macOS Push Notifications entitlement. When that capability is present, enabling sync registers for silent remote notifications; CKSyncEngine manages the CloudKit database subscription. The existing launch, foreground, and 15-minute fetch requests remain, but are not a guarantee of prompt delivery without push support. See [release setup](RELEASING.md#icloud-sync-cloudkit).

Fetched records and removed-record recovery apply together with their local sync bookkeeping. Cancelling sync, turning it off, or accepting a newer batch prevents a suspended older apply from overwriting provider settings, preferences, or fleet records.

Never synced, by design: `hooks` (sync payloads structurally cannot create or modify hook rules — they execute local binaries), machine-local paths (`claudeSwapExecutablePath`, `claudeSwapSource`, `codexProfileHomePaths`, `awsProfile`/`awsAuthMode`, `source`, `codexActiveSource`, `cookieSource`), menu-bar layout/geometry, debug settings, usage history, and cost ledgers. A provider is never auto-enabled on a Mac where its required local CLI is missing. Records carry a schema version; older app versions pause sync instead of rewriting newer payloads. The CLI does not talk to CloudKit — the running app watches `config.json`, applies CLI or hand edits locally, and syncs changed provider payloads to the fleet when iCloud sync is enabled. Remote changes written to the file are recognized as app writes and are not echoed back. The app tracks per-provider dirty state and never re-uploads unchanged state at launch.

## Notes
- Fields not relevant to a provider are ignored.
- Omitted providers are appended with defaults during normalization.
- Unknown or retired provider entries are retained with all their fields, settings, and secrets in their original array positions during unrelated saves. This also applies when plugin discovery fails or the plugin runtime is unavailable. `config providers` labels unavailable entries as `plugin (not loaded)`; `config dump` includes them but redacts their opaque fields unless `--show-secrets` is explicitly requested. Remove plugin data through explicit plugin deletion, or remove the entry by editing the file.
- When a configuration read reports an error, CodexBar preserves `config.json` during startup and later settings saves. At startup it uses temporary defaults without clearing legacy credentials; repair the file and let CodexBar reload it, or remove it and restart, before saving settings. Temporary defaults and earlier queued or staged saves cannot overwrite the repaired file after a reload. Legacy migration retries on the next launch.
- Reloading account settings from disk reloads the complete config, preserving unrelated edits. A failed config reload, plugin-settings read, or save-time config validation blocks saving until a valid full reload succeeds.
- Keep the file private; it contains secrets.
- Validate the file with `codexbar config validate` (JSON output available with `--format json`).

## Portable UI preferences

On macOS, **Settings → General → Portable preferences** exports or imports a versioned `preferences.json`
for dotfiles. UserDefaults remains the runtime owner; the file is an explicit snapshot, not a watched second
configuration source. Provider settings remain in `config.json`, which may contain credentials.

```sh
codexbar config preferences export --file ~/dotfiles/codexbar/preferences.json
codexbar config preferences import --file ~/dotfiles/codexbar/preferences.json --json
```

Export without `--file` writes JSON to stdout. The CLI exports stored overrides (unset preferences keep the
app's defaults); Settings exports the effective preferences. CLI import queues an intentional local edit:
the running app applies it through its normal settings setters, or applies it at its next launch. The CLI
reports `{"status":"queued"}`. Multiple pending imports merge, with the latest supplied value winning.
`--defaults-domain` can select an alternate app preferences domain; it defaults to `com.steipete.codexbar`.
These commands transfer macOS UI preferences and are unavailable on Linux.

```json
{
  "version": 1,
  "preferences": {
    "refreshFrequency": "fiveMinutes",
    "hidePersonalInfo": true,
    "mergeIcons": true,
    "mergedOverviewSelectedProviders": ["codex", "claude"],
    "switcherShortcuts": {
      "previous": "shift+left",
      "next": "shift+right",
      "select2": "alt+cmd+2"
    }
  }
}
```

The allowlist covers the existing iCloud preferences projection: refresh frequency and refresh-on-open;
provider status checks; session, threshold and predictive pace notifications; session/weekly thresholds
and notification windows; sound, on-screen alerts and threshold markers; pace visibility, workweek days
and tick appearance; usage/reset display; local cost display, comparisons and summary style; privacy,
blink/confetti effects, highest-usage selection, optional credits/extra usage, changelog links, currency
and alphabetical provider sorting. JSON keys match the `SyncedPreferences` fields. It additionally includes
`limitResetNotificationsEnabled`, `mergeIcons`, `mergeIconsStacked`, `switcherShowsIcons`, `mergedOverviewLayout`,
`mergedOverviewSelectedProviders`, and `switcherShortcuts`. An overview selection is applied intentionally
to the receiving Mac's active providers, including an empty selection. `weeklyProgressWorkDays: null`
restores the seven-day default. Missing keys leave the receiving Mac's settings unchanged. Unknown preference keys,
unsupported versions, invalid types and invalid shortcut mappings are rejected before applying changes.

Credentials, accounts, hooks, launch at login, global hotkeys, local paths, device identity, iCloud switches,
debug settings, and consent are excluded. Import does not enable activity-scan consent. Only the existing
iCloud projection syncs onward; reset notifications, the additional menu settings, and switcher shortcuts stay local
unless explicitly exported and imported. Import does not modify `config.json` or iCloud's remote-update suppression.

### Menu bar controls

**Settings → Menu Bar → Show all accounts in Overview** is off by default. When enabled, each selected
multi-account provider expands into account rows labeled with its account name or email. The provider’s
current account source stays in use: claude-swap/tcr, managed Codex accounts, or saved token accounts,
independently of the provider tab’s stacked/segmented layout. The six-provider cap, provider order, and
Overview selection still apply to providers before expansion; account rows do not use extra provider
slots. Rows keep each account’s cached usage and errors; missing usage stays unavailable instead of
borrowing another account’s quota. The setting adds no fetches and does not change refresh limits.
Clicking a row opens its provider tab without selecting another credential. The local additive defaults
key is `mergedOverviewAllAccounts`; older versions ignore it.

**Auto** ranks each provider's eligible quota windows from the current snapshot. An exhausted quota comes
first; otherwise a supported lane’s pace forecast that runs out before reset takes priority, with the shortest time to
depletion first. Without such a forecast, Auto chooses the highest used percentage. Ties keep provider order.
The unified highest-usage icon uses the same priority for providers set to Auto and displays the selected
window's actual percentage. Explicit metric choices and provider-specific credit-pool ordering are preserved.
This uses reported usage, duration, and reset time; it adds no observation history or background timer.

The **Layout** editor applies only to **Icon & percent**. With **Critters** or **Meter bars** selected, its footer explains which style to choose before editing.

The layout editor includes an optional **Tokens / min** value token (for example `49M/min`) using the provider’s latest reported complete minute. OpenAI supplies it through the **Tokens per minute** provider setting. It uses the same unavailable placeholder as other value tokens when no throughput is available. The optional **Tokens / min graph** token shows the last hour as a compact graph, using the maximum minute in each column and excluding minutes that are still reporting. Drag either token into your layout to enable it; default layouts include neither. The graph uses the status item’s own provider data and the standard unavailable placeholder when there are no reported minutes.

Switching from **Icon & percent** back to **Meters** or **Critters** redraws the selected style immediately, even when usage has not changed.

Custom two-line layouts show a single leading provider icon at full size beside both text rows. Merged-provider rows, multiple icons, icon-only rows, high-contrast mode, and provider-colored layouts retain inline icons.

The layout editor's **Usage** palette includes graphical bars for session, weekly, scoped weekly, and automatic windows. **Progress bars stacked** places session and weekly bars on separate rows with their reset countdowns. Bars follow the used/remaining display preference and keep balance-only automatic values as text. The compact three-character **Usage bar** remains available.

Older app versions show matching percentages in place of graphical bars. Returning to the newer version restores the bars when the older layout was unchanged; edits made in the older version take precedence.

**Surprise me** is disabled while brand icons are selected, and static brand layouts do not run the blink timer.
Your animation preference is kept for switching back to critters. If a brand image is unavailable and the legacy
layout falls back to a critter, that visible critter can still animate; stored layouts remain static.

In **Settings → Menu Bar**, inactive combined-icon controls use dimmed labels. Their titles and explanations remain readable and available to VoiceOver; label styling follows each control's enabled state, including stacked-icon restrictions. The layout size and gap controls remain independent of Merge Icons.

The open menu's persistent **Refresh** row uses a text label aligned with the other actions, without a decorative icon. Click the row, press **⌘R**, or use its VoiceOver button action to refresh.

### Provider switcher shortcuts

**Settings → General → Provider Switcher Shortcuts…** edits the same mapping as `switcherShortcuts` above.
Defaults are `left`/`right` for `previous`/`next` and `cmd+1` through `cmd+9` for `select1` through `select9`.
Selection refers to positions in the visible switcher, including Overview when present. These are local
menu shortcuts, not global provider-opening hotkeys.

Combine `ctrl`, `alt`, `shift` and `cmd` with an ASCII letter, digit, `left` or `right`; letters and digits
require Command, Control or Option. `none` disables an action. Modifier order and letter case are normalized.
Omitted actions retain their defaults. Duplicate assignments (including conflicts with defaults) and
reserved commands are rejected. Reserved combinations are `cmd+r`, `cmd+,`, `cmd+q`, `cmd+h`, `cmd+m`,
`cmd+w` and `alt+cmd+h`; Escape, Tab, Return and up/down arrows remain available to menu navigation.
