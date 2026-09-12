# CodexBar for Linux

A Qt 6 desktop app with separate Usage & Spend and Settings windows, an optional
system tray icon, and a launcher entry. The Swift `codexbar` CLI owns provider
fetching and authentication. The desktop owns polling, settings, notifications,
and a private local socket for desktop adapters. No HTTP server is needed.

## Release downloads

Starting with releases that include this integration, GitHub Releases provides
`CodexBarDesktop-v<version>-linux-x86_64.tar.gz` and
`CodexBarDesktop-v<version>-linux-aarch64.tar.gz`, each with a `.sha256` file.
These contain the desktop and optional Omarchy adapter. Download the matching
`CodexBarCLI` archive separately and keep its resource bundle beside the CLI.

The release binaries build on Ubuntu 24.04 (glibc 2.39, Qt 6.4). Install the Qt
runtime and QML modules from your distro. On older systems, build from source.
Arch/Omarchy dependencies are listed below; Ubuntu packages are listed in
`.github/actions/build-linux-desktop/action.yml` (the `-dev` packages are only
needed for building).

```sh
# Download the archive and its checksum into the same directory.
# Replace <version> below with the downloaded version (use aarch64 for ARM64):
archive='CodexBarDesktop-v<version>-linux-x86_64.tar.gz'
sha256sum -c "$archive.sha256"
tar -xzf "$archive"
cd "${archive%.tar.gz}"
python3 Integrations/Linux/install.py --cli /absolute/path/to/codexbar --omarchy
~/.local/bin/codexbar-linux --settings
```

Omit `--omarchy` on other desktops. To upgrade, quit CodexBar, install the new
archive, and reopen it. Preferences are preserved. There is no desktop auto-updater
or distro repository package yet. Ordinary CI artifacts are previews, not releases.

## Build and install

Requires Linux, C++17, make, qmake6, and Qt 6.4 or newer: Base, Declarative/Quick,
Quick Controls, Network, D-Bus, and SVG icon support. Install Qt's Wayland plugin
for Wayland sessions. On Arch/Omarchy these are `base-devel qt6-base
qt6-declarative qt6-svg qt6-wayland`.

Install a CodexBar Linux CLI release, keeping its resource bundle beside the
executable, and authenticate with the provider's CLI. From the repository root:

```sh
mkdir -p .local/linux-build
cd .local/linux-build
qmake6 ../../Integrations/Linux/codexbar-linux.pro
make -j4
cd ../..
python3 Integrations/Linux/install.py --cli /absolute/path/to/codexbar
~/.local/bin/codexbar-linux --settings
```

Add `--omarchy` to install the compact Omarchy adapter. Add `--no-autostart` to
disable starting at login. Installation is per user, preserves settings, and
backs up existing preferences before changes. Reinstallation preserves disabled
autostart. A release archive can also be installed without a checkout:

```sh
# Inside an extracted CodexBarDesktop archive:
python3 Integrations/Linux/install.py --cli /absolute/path/to/codexbar --omarchy
```

To create an archive from a local build, run
`python3 Integrations/Linux/package.py --version 0.1.0`. The archive contains only
the app, installer, icon, adapter, license, and instructions. It needs compatible
system Qt/glibc libraries and a separately installed CodexBar CLI; it is not an
AppImage or a distro-native package. Build on the oldest distro you intend to support.

Qt supports Wayland and X11. The tray uses Qt's desktop integration (StatusNotifier
or X11 tray host). GNOME may require a tray extension; the launcher and windows
work without a tray. Omarchy installation hides the duplicate tray by default.
KDE, GNOME, and other compositor sessions still need hands-on compatibility testing.

## Windows and behavior

Settings is divided into General, Providers, and Advanced. It controls
provider/source selection, account index, all-account display,
identity visibility, refresh interval, status, local spending, notifications, and
tray visibility. Account selectors choose displayed usage; they do not change the
provider CLI's login. Choose `custom` to pick providers from the installed CLI's catalog and move them
up or down. Only that ordered list is queried, sequentially; a failed provider
retains its previous result while healthy providers update. Account selectors
apply to a single-provider query; custom lists use each provider's default account.

Sign in and Sign out open the Codex or Claude CLI in the default terminal using
`xdg-terminal-exec` (an optional dependency). Sign out asks for confirmation.
The app does not read terminal output or store credentials. Finish the flow, then
refresh usage. These controls manage the active CLI session; browser imports,
token-account editing and Mac managed profiles are not implemented here.

Usage displays used or remaining quota, reset times, pace, credits, status, generic provider
details, and charts. Unknown values stay unknown. Identity is hidden by default. Display preferences control reset countdowns,
absolute times, pace visibility, and low-quota colors. The tray can show two quota
meters for the first displayed provider or a static icon. Unknown meters remain
empty tracks. The tooltip identifies the displayed providers and stale data.
Omarchy's popup shares the quota/reset preferences.

Start-at-login changes apply immediately from Settings. Other preferences use Save.
Omarchy installation enables theme following by default: colors are read from
`$XDG_STATE_HOME/omarchy/current/theme/colors.toml` (normally `~/.local/state`) and
checked every ten seconds. Missing or incomplete themes fall back to Qt's system
palette. The preference can be disabled on any desktop.
Local Spending shows Codex/Claude history across accounts on this machine, with
calendar-day and 30-day estimates, token mix, provenance, and coverage. Estimates
are not invoices. Opening spending scans independently of quota polling, with a
five-minute cache; Refresh forces a new scan.

Quota polling defaults to five minutes. Optional refresh-on-open updates usage
when its window opens. Refresh and Ctrl+R update the selected tab independently;
Ctrl+, opens Settings, and Ctrl+Q quits. Queries never overlap within each stream,
stop after 60 seconds, and cap output at 8 MiB. Failed refreshes retain previous
results with a stale indicator. Changing selection rejects old in-flight results.
Optional notifications use the desktop's D-Bus notification service for remaining
quota threshold crossings, observed resets, and service-status transitions.
Startup, provider errors, and ambiguous multi-account results stay silent.

Closing a window leaves the backend running. Quit from the usage window or tray,
or use `codexbar-linux --quit`. Launching again opens the existing process.
Preferences live in `$XDG_CONFIG_HOME/codexbar/linux.json` (normally `~/.config`),
written atomically with user-only permissions. Invalid files are never overwritten:
fix or remove the file and restart. Authentication remains in the CLI's stores.

## Adapter interface

```sh
codexbar-linux --background
codexbar-linux --usage
codexbar-linux --settings
codexbar-linux --spending
codexbar-linux --refresh
codexbar-linux --snapshot
codexbar-linux --configure '{"provider":"both","refreshSeconds":300}'
codexbar-linux --autostart status # also enable or disable
codexbar-linux --quit
```

Snapshot, refresh, configure, autostart, and quit require an existing process. UI commands
start one when needed. IPC clients load no GUI plugin. `--cli PATH` and `--no-tray`
apply when starting a new instance. The private, same-user local socket lives at
`$XDG_RUNTIME_DIR/codexbar-linux/desktop.sock`; requests and replies are newline
terminated JSON. Snapshot schema version 1 includes compact provider windows,
summary, update time, busy/stale/error state, and spending availability. It excludes account identity, CLI paths, and credential configuration.
It includes display values and reset text for adapters. Adapters should check `schemaVersion`, tolerate
unknown fields, and treat a missing backend as unavailable.

## Validation and removal

```sh
node --test Integrations/Omarchy/test.mjs Integrations/Omarchy/notifications.test.mjs
python3 Integrations/Omarchy/test_install.py
python3 Integrations/Linux/tests/test_desktop.py
python3 Integrations/Linux/tests/test_package.py
# Account-action test: qmake6 Integrations/Linux/tests/accounts.pro in a build directory,
# then make and run ./tst_accounts. Uses a fake terminal and fake provider CLIs.
```

Runtime tests isolate HOME/XDG paths and use a fake CLI and offscreen Qt. Set
`CODEXBAR_TEST_PLATFORM=xcb` to exercise X11 on a session with DISPLAY access.

To uninstall, quit CodexBar and remove `~/.local/bin/codexbar-linux`,
`$XDG_DATA_HOME/applications/com.steipete.CodexBar.desktop`,
`$XDG_DATA_HOME/icons/hicolor/scalable/apps/codexbar.svg`, and
`$XDG_CONFIG_HOME/autostart/com.steipete.CodexBar.desktop`.
The default data/config directories are `~/.local/share` and `~/.config`.
Preferences and their backups can be retained for a later reinstall.
