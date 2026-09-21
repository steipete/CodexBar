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

The bar shows each provider's session quota, weekly quota and weekly pace, as in
`5H 37% · 7D 61% · +14%`. A positive pace is a deficit against the sustainable
weekly rate and a negative one a reserve, matching the menu bar on macOS. A lane
the provider does not report contributes no text and no separator, so a
weekly-only account reads `7D 61% · +14%`, and a pace CodexBar cannot compute
contributes nothing rather than a placeholder. **Show pace** hides it entirely.
Used or remaining percentages follow the quota preference. A cap scoped to one
model stays out of the bar unless **Show per-model caps in the bar** is enabled,
because most providers that publish them restate a general lane; the popup
always lists them.
**Providers in the bar** limits how many providers the bar shows, two by default,
and counts the rest, as in `CX 5H 37% · 7D 61%  ·  CL 7D 11%  +2`. It is display
only: every configured provider is still polled and listed in the popup. Four
providers each showing a session lane, a weekly lane and a pace take about 1500
logical pixels, so raise it, or set it to **All**, where the display has room.

Each provider is marked by its own logo, tinted to the bar's foreground so
themes still apply. A provider whose logo is not installed keeps a short text tag
rather than a gap, and a count follows the marks when the display limit hides
providers. The installer and the release archive carry the marks beside the
adapter, and `barEntries` supplies one tag-and-text pair per displayed provider;
an older backend publishes none and gets the joined label instead.

The widget reads the desktop's private IPC snapshot every five seconds; it never
runs provider queries itself. If the backend is absent, opening Usage & Spend or
Settings starts it. Refresh requests one shared backend refresh. Unknown quota
stays unavailable, and old data carries a stale indicator. The popup contains no
account identities or settings form. Desktop notifications and clipboard actions
use Qt/D-Bus, so the app also works outside Omarchy.

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
