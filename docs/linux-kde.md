---
summary: "Install CodexBar's Linux backend and a native KDE Plasma 6 panel UI on Fedora."
read_when:
  - "You want CodexBar usage in a Fedora KDE panel."
  - "Updating or debugging the Fedora/KDE installer."
---

# Fedora KDE integration

CodexBar's provider and parsing layer already supports Linux through the standalone
`CodexBarCLI` release. The macOS app UI uses SwiftUI and AppKit, so Fedora uses a
native Plasma 6/Kirigami panel widget backed by the same JSON output.

## Install

Run from the CodexBar checkout:

```bash
./Scripts/install-fedora-kde.sh --add-to-panel
```

The installer:

- verifies Fedora and Plasma 6;
- downloads the latest official static Linux CLI release;
- verifies the published SHA-256 checksum;
- installs `codexbar` into `~/.local/bin`;
- installs the tested KDE Plasma widget;
- applies the Plasma 6.6 boolean-binding compatibility fixes;
- optionally adds it to the first Plasma panel.

The Plasma widget is the MIT-licensed
[`psimaker/codexbar-plasmoid`](https://github.com/psimaker/codexbar-plasmoid),
pinned by default to a revision tested with this repository. Override
`CODEXBAR_KDE_REF` to test a newer widget revision.

## Verify

The check is read-only and does not probe live provider accounts:

```bash
./Scripts/install-fedora-kde.sh --check
```

To verify a provider separately:

```bash
codexbar usage --provider codex --format json --pretty
codexbar usage --provider claude --format json --pretty
```

Provider probes can invoke local provider CLIs. Run those commands only when the
relevant provider is already signed in.

## Configure

Open the widget settings from the Plasma panel. The KDE UI supports:

- all provider IDs exposed by the Linux CLI;
- merged or per-provider panel meters;
- provider tabs and an overview;
- session, weekly, monthly, and named quota windows;
- reset countdowns and pace;
- credits and Codex reset credits;
- local Codex/Claude cost summaries;
- provider status and account identity;
- provider-specific CLI errors instead of a generic empty state;
- dashboard/status links and refresh controls.

The CLI and widget use `~/.config/codexbar/config.json` (or the legacy
`~/.codexbar/config.json`) for provider credentials and source settings. Browser
cookie import and WebKit scraping remain macOS-specific; on Linux use provider
CLI/OAuth/API authentication or manual cookies where the provider supports them.

## Update or customize

Rerun the installer to update the CLI and widget:

```bash
./Scripts/install-fedora-kde.sh
```

Useful overrides:

```bash
CODEXBAR_VERSION=v0.43.0 ./Scripts/install-fedora-kde.sh
CODEXBAR_KDE_REF=<git-ref> ./Scripts/install-fedora-kde.sh
CODEXBAR_BIN_DIR="$HOME/bin" ./Scripts/install-fedora-kde.sh
CODEXBAR_LINUX_VARIANT=glibc ./Scripts/install-fedora-kde.sh
```

Use `--skip-cli`, `--skip-widget`, or `--no-restart` for development workflows.
The static `musl` CLI is the Fedora default because it avoids host `libcurl`
ABI/version mismatches. Set `CODEXBAR_LINUX_VARIANT=glibc` only when you
specifically need the dynamically linked build.
