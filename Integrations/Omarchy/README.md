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
