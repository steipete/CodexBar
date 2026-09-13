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
## Distro install recipes

No distribution packages the desktop app, so the sections below install the Qt 6 runtime
for your distro and then the CLI and desktop artifacts from the release archives. The
download commands resolve the newest release that actually ships the asset, so they keep
working after an upgrade and do not hardcode a version.

Verified runtime floors: glibc 2.39 and Qt 6.4. Debian 13 (Qt 6.8), Ubuntu 24.04 (Qt 6.4),
Ubuntu 26.04 (Qt 6.10), Fedora 43-45 (Qt 6.11), and current Arch (Qt 6.11) all clear them;
older releases need the source build above. The CLI resolves `VERSION` and
`CodexBar_CodexBarCore.bundle/` relative to its own executable, so expose it through a
wrapper that execs it by absolute path, never as a bare-name symlink on `PATH`.

The recipes are POSIX shell. CachyOS defaults to fish and Omarchy auto-launches it from
bash, so run a block in a bash subshell (`bash`, paste, `exit`) or save it to a file and run
`bash file.sh`; on fish add the tarball CLI to `PATH` with `fish_add_path ~/.local/bin`.

### Arch Linux family (Arch, CachyOS, EndeavourOS, Omarchy)

```sh
sudo pacman -S --needed python qt6-base qt6-declarative qt6-svg qt6-wayland

# Qt Quick Controls and the Fusion style live in qt6-declarative on Arch.
paru -S codexbar-cli            # or yay -S codexbar-cli; installs the `codexbar` wrapper
```

Then run the desktop app recipe below, which finds `codexbar` on `PATH`. The AUR package follows
upstream with a short lag. Arch has no AUR helper by default and CachyOS only ships one on some
installs, so with neither `paru` nor `yay` available use the tarball CLI recipe below instead.

### Fedora

```sh
sudo dnf install python3 qt6-qtbase qt6-qtdeclarative qt6-qtsvg qt6-qtwayland
```

Qt Quick Controls ship inside `qt6-qtdeclarative`, which also provides the retired
`qt6-qtquickcontrols2` name. Install the CLI with the tarball recipe below, then run the
desktop app recipe.

### Debian and Ubuntu

```sh
# Debian 13 "trixie", Ubuntu 26.04 and later
sudo apt install python3 qml6-module-qtquick qml6-module-qtquick-controls \
  qml6-module-qtquick-layouts qml6-module-qtquick-templates qml6-module-qtquick-window \
  libqt6core6t64 libqt6gui6 libqt6widgets6 libqt6network6 libqt6dbus6 \
  libqt6qml6 libqt6quick6 libqt6quickcontrols2-6 libqt6svg6 qt6-wayland
```

Ubuntu 24.04 "noble" carries the time64 names for four of those libraries, and sits exactly
on the glibc 2.39 / Qt 6.4 floor:

```sh
sudo apt install python3 qml6-module-qtquick qml6-module-qtquick-controls \
  qml6-module-qtquick-layouts qml6-module-qtquick-templates qml6-module-qtquick-window \
  libqt6core6t64 libqt6gui6t64 libqt6widgets6t64 libqt6network6t64 libqt6dbus6t64 \
  libqt6qml6 libqt6quick6 libqt6quickcontrols2-6 libqt6svg6 qt6-wayland
```

Install the CLI with the tarball recipe below, then run the desktop app recipe.

### Install the desktop app from a release archive (any distro, no root)

Run this in an empty directory, with the CLI already on `PATH`:

```sh
arch=$(uname -m)                                # x86_64 or aarch64
api=https://api.github.com/repos/steipete/CodexBar/releases
desktop=$(curl -fsSL "$api?per_page=30" |
  grep -Po '"browser_download_url": *"\K[^"]*CodexBarDesktop-v[0-9][0-9.]*-linux-'"$arch"'\.tar\.gz' | head -n1)
test -n "$desktop" || { echo "no desktop archive for $arch yet" >&2; exit 1; }
curl -fsSLO "$desktop"
curl -fsSLO "$desktop.sha256"
sha256sum -c "$(basename "$desktop").sha256"
tar -xzf "$(basename "$desktop")"
cd "$(basename "$desktop" .tar.gz)"
python3 Integrations/Linux/install.py --cli "$(command -v codexbar)"
~/.local/bin/codexbar-linux --settings
```

Add `--omarchy` only on Omarchy, and `--no-autostart` to skip the login autostart.

### Install the CLI from a release tarball (any distro, no root)

```sh
arch=$(uname -m)
api=https://api.github.com/repos/steipete/CodexBar/releases
cli=$(curl -fsSL "$api?per_page=30" |
  grep -Po '"browser_download_url": *"\K[^"]*CodexBarCLI-v[0-9][0-9.]*-linux-'"$arch"'\.tar\.gz' | head -n1)
test -n "$cli" || { echo "no CLI archive for $arch" >&2; exit 1; }
cli_dir="$HOME/.local/lib/codexbar-cli"
mkdir -p "$cli_dir"
curl -fsSLO "$cli"
curl -fsSLO "$cli.sha256"
sha256sum -c "$(basename "$cli").sha256"
tar -xzf "$(basename "$cli")" -C "$cli_dir"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexec %s/codexbar "$@"\n' "$cli_dir" > "$HOME/.local/bin/codexbar"
chmod +x "$HOME/.local/bin/codexbar"

export PATH="$HOME/.local/bin:$PATH"
codexbar config providers
```

On musl systems (Alpine, musl Void) use the `CodexBarCLI-v<version>-linux-musl-$arch` asset
instead. Make sure `~/.local/bin` is on `PATH`. Upgrading is rerunning the same commands:
the installer preserves preferences, and preserves a disabled autostart.

### Tray, terminal sign-in, and removal

- GNOME needs an extension for the status icon: `gnome-shell-extension-appindicator` on
  Fedora, Debian, and Ubuntu. KDE and the other desktops need nothing extra.
- Settings' Sign in / Sign out buttons open your terminal through `xdg-terminal-exec`,
  which is optional and packaged in the AUR, Fedora, Debian, and Ubuntu. Without it the
  buttons do nothing; you can still authenticate with the provider's own CLI.
- Remove the desktop app after quitting it: `~/.local/bin/codexbar-linux`,
  `$XDG_DATA_HOME/applications/com.steipete.CodexBar.desktop`,
  `$XDG_DATA_HOME/icons/hicolor/scalable/apps/codexbar.svg`, and
  `$XDG_CONFIG_HOME/autostart/com.steipete.CodexBar.desktop`.
- Remove the CLI with `paru -Rns codexbar-cli` on the Arch family, or by deleting
  `~/.local/bin/codexbar` and `~/.local/lib/codexbar-cli`. Preferences in
  `$XDG_CONFIG_HOME/codexbar/linux.json` can stay for a later reinstall.
- If the GitHub API rate limit blocks the asset lookup, `gh release download steipete/CodexBar`
  resolves the same archives.

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
