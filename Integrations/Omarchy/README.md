# CodexBar for Omarchy

A compact Quickshell bar adapter for the [Linux desktop app](../Linux/README.md).
The popup shows remaining quota and reset times; Usage & Spend and Settings open
separate native windows. One desktop process owns provider polling, settings,
notifications, and spending scans, including when multiple monitors show the bar.
Requires Omarchy's plugin-based shell; older Waybar installations are not supported.

Build the Linux desktop app first, then run from the repository root:

```sh
python3 Integrations/Linux/install.py --omarchy --cli /absolute/path/to/codexbar
~/.local/bin/codexbar-linux --background
omarchy restart shell
```

The installer migrates old widget settings to `~/.config/codexbar/linux.json`,
backs up `shell.json`, and archives the old plugin outside the plugin discovery
directory. Existing desktop preferences take precedence over old widget settings.
It also adds a launcher and login autostart entry. Provider authentication remains
with the installed Linux CLI. The CLI resource bundle must stay beside its binary.

Providers that report a cap scoped to one model alongside their general quota,
such as Claude's per-model weekly window, contribute a lane named by the
provider's own title. Those lanes follow the standard session, weekly and
additional windows, so a consumer resolving a cadence by first match still finds
the general quota. A window the provider cannot measure, such as Zed's overdue
invoice or a reset-only pool, is omitted rather than shown as exhausted.

The widget reads the desktop's private IPC snapshot every five seconds; it never
runs provider queries itself. If the backend is absent, opening Usage & Spend or
Settings starts it. Refresh requests one shared backend refresh. Unknown quota
stays unavailable, and old data carries a stale indicator. The popup contains no
account identities or settings form. Desktop notifications and clipboard actions
use Qt/D-Bus, so the app also works outside Omarchy.

The bar marks each displayed provider with its logo, tinted to the bar's foreground
color. Missing logos keep the provider's text tag. It retains the compact quota
percentage, two-entry limit, and `+N` count for additional entries; all configured
providers remain in the popup and continue polling. Both checkout and release
archive installs include the existing Mac app SVGs. The backend supplies structured
`barEntries`, and older backends fall back to their plain `summary` text.

Three display preferences extend that bar. All are off, or at the count the bar
already used, so an upgrade changes nothing. None of them changes what is polled:
a provider the bar hides is still queried, listed in the popup and notified about.

**Show session, weekly and pace in the bar** gives each provider its session
quota, weekly quota and weekly pace, as in `5H 37% · 7D 61% · +14%`. A positive
pace is a deficit against the sustainable weekly rate and a negative one a
reserve, matching the menu bar on macOS. A lane the provider does not report
contributes no text and no separator, so a weekly-only account reads
`7D 61% · +14%`, and a pace CodexBar cannot compute contributes nothing rather
than a placeholder. **Show pace** hides the pace on its own.

**Show per-model caps in the bar** adds a cap a provider scopes to one model,
named by the provider's own title. Caps the provider labels as one model's own
budget, Claude's per-model weekly windows such as Fable and Codex's per-model
limits such as Codex Spark, always show. Other per-model lanes, such as
Antigravity's model pools, show only while they bind harder than the general
lane beside them, because they often repeat it.

**Providers in the bar** sets how many providers appear, two by default, and
`0` shows every one. Four providers each showing a session lane, a weekly lane
and a pace take about 1500 logical pixels, so raise it where the display has room.

The tray tooltip keeps its own compact two-provider form.

The `steipete.codexbar` layout entry in `~/.config/omarchy/shell.json` now accepts
only `desktopExecutable` (default `codexbar-linux`) in addition to its ID. Configure
providers and their order, accounts, status, costs, notifications, display, and polling in the Settings
window. Enabling the standalone tray with quota meters is optional; Omarchy installation hides it
to avoid a duplicate indicator.

Remove the layout entry and `~/.config/omarchy/plugins/steipete.codexbar` to remove
the adapter. The desktop app and its autostart are independent; see the Linux
README for uninstall instructions.

```sh
omarchy plugin validate Integrations/Omarchy
node --test Integrations/Omarchy/test.mjs Integrations/Omarchy/notifications.test.mjs
python3 Integrations/Omarchy/test_install.py
```
