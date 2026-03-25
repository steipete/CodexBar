---
summary: "Ubuntu/Linux dashboard frontend built on top of CodexBarCLI."
read_when:
  - "You want to install CodexBar on Ubuntu."
  - "You are extending or debugging the Linux frontend."
---

# CodexBar Linux

CodexBar Linux is a lightweight Ubuntu-friendly frontend that sits on top of `CodexBarCLI`.
It does not try to recreate the macOS menu bar app.
Instead, it runs a local refresher loop, writes dashboard artifacts to disk, and opens a browser dashboard.

## What it installs
- `codexbar`: the existing CLI backend
- `codexbar-linux`: the Linux frontend
- `~/.local/share/applications/codexbar-linux.desktop`: desktop launcher

## Install from source

```bash
./bin/install-codexbar-linux.sh
```

If `swift` is missing, the installer bootstraps the official Swift toolchain via `swiftly` first.
Then it builds `CodexBarCLI` and `CodexBarLinux` in release mode and installs them into `~/.local/bin`.

## Quick start

```bash
codexbar --format json --pretty
codexbar-linux launch
```

`codexbar-linux launch` does three things:
- fetches the latest provider data through `codexbar`
- starts a background refresh loop
- opens the generated dashboard in your default browser

Stop it with:

```bash
codexbar-linux stop
```

## Files written by the frontend

By default the Linux frontend writes to:

```bash
~/.local/state/codexbar-linux
```

Or `$XDG_STATE_HOME/codexbar-linux` when `XDG_STATE_HOME` is set.

Files:
- `index.html`: browser dashboard
- `snapshot.json`: latest raw CLI JSON
- `waybar.json`: small JSON payload for custom Waybar modules
- `codexbar-linux.log`: background refresher log
- `codexbar-linux.pid`: running refresher PID

## Commands

```bash
codexbar-linux launch
codexbar-linux serve
codexbar-linux refresh
codexbar-linux open
codexbar-linux stop
```

Useful flags:
- `--interval 60`
- `--provider codex`
- `--source cli`
- `--status`
- `--cli-path /absolute/path/to/CodexBarCLI`
- `--output-dir /tmp/codexbar-linux`

## Waybar integration

`waybar.json` is rewritten on every refresh. A minimal custom module can read it, for example:

```json
{
  "custom/codexbar": {
    "exec": "cat ~/.local/state/codexbar-linux/waybar.json",
    "return-type": "json",
    "interval": 5
  }
}
```

The frontend is still browser-based, so this is not an AppIndicator tray port.
It is meant to be dependency-free and easy to install on plain Ubuntu.
