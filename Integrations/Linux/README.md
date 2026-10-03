# CodexBar for Linux

A Qt 6 desktop app with an opt-in compact Quick View, separate Usage & Spend and Settings
windows, an optional system tray icon, and a launcher entry. The Swift `codexbar` CLI owns provider
fetching and authentication. The desktop owns polling, settings, notifications,
and a private local socket for desktop adapters. No HTTP server is needed.

## Install release archives

Desktop archives are published for x86_64 and ARM64 alongside the separate
CodexBarCLI archives, each with a `.sha256` file. The desktop uses system Qt;
release binaries require glibc 2.39+ and Qt 6.4+. Ubuntu 24.04 and Debian 13 meet
these floors. Older systems need a source build. The musl CLI archives are for
CLI-only use on distributions such as Alpine; they do not make the glibc desktop
archive compatible with musl.

### Runtime packages

Install the packages for your distribution before downloading the archives.
These include the download tools and Python installer; development packages are
only needed for a source build.

Arch family, including Omarchy:

```sh
sudo pacman -S --needed curl python qt6-base qt6-declarative qt6-svg qt6-wayland
```

Fedora:

```sh
sudo dnf install curl python3 qt6-qtbase qt6-qtdeclarative qt6-qtsvg qt6-qtwayland
```

Qt Quick Controls and the Fusion style ship in `qt6-declarative` on Arch and
`qt6-qtdeclarative` on Fedora. Debian and Ubuntu split QML modules into separate
packages, including WorkerScript.

Ubuntu 24.04 (Noble):

```sh
sudo apt update
sudo apt install curl python3 qml6-module-qtquick qml6-module-qtquick-controls \
  qml6-module-qtquick-layouts qml6-module-qtquick-templates qml6-module-qtquick-window \
  qml6-module-qtqml-workerscript libqt6widgets6t64 libqt6svg6 qt6-wayland
```

Debian 13 (Trixie):

```sh
sudo apt update
sudo apt install curl python3 qml6-module-qtquick qml6-module-qtquick-controls \
  qml6-module-qtquick-layouts qml6-module-qtquick-templates qml6-module-qtquick-window \
  qml6-module-qtqml-workerscript libqt6widgets6 libqt6svg6 qt6-wayland
```

### Download, verify, and install

Run this block in `sh` or `bash` (from fish, enter `bash` first). It selects the
latest stable GitHub release, downloads both matching archives, and stops on any
download or checksum failure. The subshell leaves your current directory and
shell options unchanged. It uses a fresh temporary directory on each run; the
CLI and its resource bundle are kept together under `~/.local/lib/codexbar-cli`.

```sh
(
set -eu
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
api=https://api.github.com/repos/steipete/CodexBar/releases/latest
curl -fsSL "$api" -o release.json
version=$(python3 -c 'import json; print(json.load(open("release.json"))["tag_name"])')
base="https://github.com/steipete/CodexBar/releases/download/$version"
cli="CodexBarCLI-$version-linux-$arch.tar.gz"
desktop="CodexBarDesktop-$version-linux-$arch.tar.gz"
for archive in "$cli" "$desktop"; do
  curl -fSL "$base/$archive" -o "$archive"
  curl -fSL "$base/$archive.sha256" -o "$archive.sha256"
  sha256sum -c "$archive.sha256"
done
# Neither archive is extracted until both checksums have passed.
cli_dir="$HOME/.local/lib/codexbar-cli"
mkdir -p "$cli_dir" "$HOME/.local/bin"
tar -xzf "$cli" -C "$cli_dir"
ln -sfn "$cli_dir/codexbar" "$HOME/.local/bin/codexbar"
"$HOME/.local/bin/codexbar" --version
tar -xzf "$desktop"
cd "${desktop%.tar.gz}"
python3 Integrations/Linux/install.py --cli "$HOME/.local/bin/codexbar"
)
```

Add `--omarchy` to the installer command only on Omarchy, or `--no-autostart` to
disable starting at login. Then open the installed app:

```sh
~/.local/bin/codexbar-linux --settings
```

Put `~/.local/bin` on your PATH to use `codexbar` without its full path. The
symlink resolves to the CLI installation directory; keep `VERSION` and
`CodexBar_CodexBarCore.bundle` there when upgrading. Homebrew and the AUR
`codexbar-cli` package are alternative CLI installation methods; with an existing
CLI, pass its absolute path to the desktop installer instead.

If the unauthenticated GitHub API is rate-limited, download the four matching
files from [GitHub Releases](https://github.com/steipete/CodexBar/releases/latest),
or use `gh release download --repo steipete/CodexBar --pattern 'CodexBar*-linux-x86_64.tar.gz*'`
(substitute `aarch64` for ARM64). In a fresh directory, verify both `.sha256`
files successfully before extracting either archive, then use the installation
commands above with the downloaded filenames.

To upgrade, quit CodexBar, rerun the installation block, and reopen it.
Preferences and disabled autostart are preserved. There is no desktop
auto-updater or distro repository package yet. Ordinary CI artifacts are
previews, not releases. See [validation and removal](#validation-and-removal)
for uninstall paths.

Managed configuration symlinks are preserved: the installer updates their targets
for preferences, launcher entries, autostart, and the Omarchy layout. JSON remains
UTF-8, including existing glyphs. Installed binaries and icons replace links at
their destination; existing Omarchy adapter links, including dangling links, are
archived before the new adapter is installed.

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
the app, installer, icons, adapter, license, and instructions. The Omarchy adapter
includes the provider SVG logos already shipped by the Mac app. It needs compatible
system Qt/glibc libraries and a separately installed CodexBar CLI; it is not an
AppImage or a distro-native package. Build on the oldest distro you intend to support.
The executable is resolved before packaging, so `--binary` may point to a symlink.

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

Ordinary launch and `--usage` open the full Usage & Spend window. Quick View opens
with `--quick-view`, from the tray menu, or by clicking the tray icon after enabling
"Use compact Quick View from the tray" in Settings (off by default). It presents
an Overview and provider tabs with the same provider icons used by the macOS menu, compact quota meters,
reset times, pace, and optional local cost. The footer opens the full Usage & Spend
window, Settings, About, or Quit. `--dashboard` also opens the full Usage & Spend window
directly; `--spending` opens its Spending tab. The full Usage & Spend window retains
generic provider details and charts. Unknown values stay unknown. Identity is hidden by default. Display preferences control reset countdowns,
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
when Quick View or the full usage window opens. Refresh and Ctrl+R update the selected tab independently;
Ctrl+, opens Settings, and Ctrl+Q quits. Queries never overlap within each stream,
stop after 60 seconds, and cap output at 8 MiB. Failed refreshes retain previous
results with a stale indicator. Changing selection rejects old in-flight results.
Optional notifications use the desktop's D-Bus notification service for remaining
quota threshold crossings, observed resets, and service-status transitions.
Startup, provider errors, and ambiguous multi-account results stay silent.

Closing a window leaves the backend running. Quit from Quick View or the tray,
or use `codexbar-linux --quit`. Launching again opens the existing process.
Preferences live in `$XDG_CONFIG_HOME/codexbar/linux.json` (normally `~/.config`),
written atomically with user-only permissions. Invalid files are never overwritten:
fix or remove the file and restart. Authentication remains in the CLI's stores.

## Adapter interface

```sh
codexbar-linux --background
codexbar-linux --usage
codexbar-linux --quick-view
codexbar-linux --dashboard
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
summary, update time, busy/stale/error state, and spending availability. `barEntries`
contains `{provider, tag, text}` for the same first two entries shown in `summary`,
with quota text already formatted for the used/remaining preference. Adapters may
replace the tag with a local logo and count additional `entries` as `+N`; older
backends omit this field, so adapters should fall back to `summary`.
The snapshot excludes account identity, CLI paths, and credential configuration.
It includes display values and reset text for adapters. Adapters should check `schemaVersion`, tolerate
unknown fields, and treat a missing backend as unavailable.
Measured provider-scoped windows follow the standard windows and require a stable, nonempty identifier.
Their exported `key` values are opaque and remain stable for the lifetime of the backend process.
Antigravity quota-summary buckets appear once with their family titles. Each family's
most constrained bucket keeps its leading position for tray meters and summary text;
its key and alert history stay with the bucket when a different bucket leads.

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
