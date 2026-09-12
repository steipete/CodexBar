# CodexBar for Omarchy

Native Quickshell bar widget for Omarchy's plugin-based shell. Uses the official
Linux CLI, the current Omarchy theme, and its standard keyboard-aware popup.
No separate daemon or network listener. This does not support older Waybar-based
Omarchy installations.

Install a Linux `codexbar` release (keep its resource bundle alongside the binary),
then run from the repository root:

```sh
python3 Integrations/Omarchy/install.py --executable /absolute/path/to/codexbar
```

The installer backs up `shell.json`, copies the plugin into the user plugin
directory, and adds it to the right side of the bar. The shell hot-reloads it and
loads it again at login. Existing layout entries are preserved.

The default provider is Codex. Authenticate with the provider's CLI first. Use
`--provider both` for Codex and Claude or another CodexBar provider ID. Provider
support and authentication are the same as the installed Linux CLI; this is a
usage frontend, not a port of macOS account management or browser imports.

Click the bar label for usage windows, credits and reset countdowns. Percentages
show **remaining** quota. Middle/right-click or press **R** in the popup to
refresh; **Escape** closes it. Polling defaults to five minutes, never overlaps,
and has a 60-second deadline. Failed refreshes keep the last response with a
stale warning. Provider failures remain separate from successful providers.
The widget does not display account identities or raw provider errors.

The `steipete.codexbar` entry in `~/.config/omarchy/shell.json` accepts `executable`,
`provider`, and `refreshSeconds` (minimum 60). To remove the widget, remove its
layout entry and user plugin directory, or use `omarchy plugin remove`.

Validation:

```sh
node --test Integrations/Omarchy/test.mjs
omarchy plugin validate Integrations/Omarchy
```
