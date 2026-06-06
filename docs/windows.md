# CodexBar for Windows

CodexBar's Windows support is a native notification-area companion. It is separate from the SwiftUI/AppKit menu bar app because that stack is macOS-only.

The Windows app currently provides:

- a single-instance native tray process
- left-click or right-click taskbar menu access
- provider quota rows from local JSON snapshots or command probes
- reset countdowns, health colors, and source links
- a per-user settings file under `%APPDATA%\CodexBar`
- self-contained `win-x64` and `win-arm64` publish targets
- an optional Inno Setup installer

## Build

Requirements:

- Windows 10 2004 or newer
- .NET 8 SDK

```powershell
.\Scripts\build_windows.ps1 test
.\Scripts\build_windows.ps1 build -Runtime win-x64
.\Scripts\build_windows.ps1 publish -Runtime win-x64
```

Use `win-arm64` on Windows on Arm.

## Installer

Install Inno Setup 6, then run:

```powershell
.\Scripts\build_windows.ps1 installer -Runtime win-x64
```

The installer lands under `Output\CodexBar-Setup-x64.exe`.

## Run

```powershell
.\Scripts\build_windows.ps1 run
```

The first run creates:

```text
%APPDATA%\CodexBar\windows-settings.json
%APPDATA%\CodexBar\codex.sample.json
```

## Probe Contract

Each provider can read a JSON snapshot file or run a command that prints one JSON object. This keeps the native tray independent from the macOS Swift provider engine while giving provider ports a stable Windows seam.

```json
{
  "id": "codex",
  "name": "Codex",
  "health": "healthy",
  "window": "weekly",
  "remaining": 42,
  "limit": 100,
  "unit": "credits left",
  "resetsAt": "2026-06-08T12:00:00Z",
  "updatedAt": "2026-06-06T12:00:00Z",
  "detail": "Replace this sample with a real provider probe.",
  "sourceUrl": "https://codexbar.app"
}
```

`health` accepts `healthy`, `busy`, `warning`, `failing`, or the aliases `ok`, `running`, `warn`, and `error`.

## Settings

Example `%APPDATA%\CodexBar\windows-settings.json`:

```json
{
  "refreshIntervalMinutes": 5,
  "openMenuOnLeftClick": true,
  "providers": [
    {
      "id": "codex",
      "name": "Codex",
      "enabled": true,
      "snapshotPath": "%APPDATA%\\CodexBar\\codex.json"
    },
    {
      "id": "claude",
      "name": "Claude",
      "enabled": true,
      "command": "codexbar",
      "arguments": ["usage", "--provider", "claude", "--json"],
      "timeoutSeconds": 20
    }
  ]
}
```

The app never writes provider tokens into this file. Command probes should read credentials from their own native store, environment, or provider CLI.

## Release CI

The Windows workflow builds and tests the native app on `windows-latest`, publishes `win-x64` and `win-arm64` artifacts, and compiles Inno installers. Tag builds sign Windows executables and installers with Azure Trusted Signing when the same secret names used by OpenClaw Windows CI are configured:

- `AZURE_TENANT_ID`
- `AZURE_CLIENT_ID`
- `AZURE_CLIENT_SECRET`
- `AZURE_SUBSCRIPTION_ID`

The signing account and certificate profile are pinned in `.github/workflows/ci.yml`.
