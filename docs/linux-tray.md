---
summary: "Linux tray executable details, runtime config, and limitations."
read_when:
  - Running CodexBar as a native Linux tray process
  - Debugging Linux tray refresh/runtime behavior
  - Packaging Linux tray binaries
---

# Linux tray (MVP)

`CodexBarLinuxTray` is a Linux-only executable target that reuses `CodexBarCore` provider descriptors and
fetch pipelines, then publishes the current state to the tray and `WidgetSnapshotStore`.

## Build and run

```bash
swift build -c debug --product CodexBarLinuxTray
./.build/debug/CodexBarLinuxTray
```

CI/non-GUI mode:

```bash
CODEXBAR_TRAY_STDOUT_ONLY=1 ./.build/debug/CodexBarLinuxTray
```

## Data + config

- Providers, source mode, and API key overrides come from `~/.codexbar/config.json`.
- Linux tray runtime settings come from `~/.codexbar/linux-tray.json`.
- Credentials fallback file (optional): `~/.codexbar/credentials.json`.
  - Shape: `{ "provider-id": "api-key" }`
  - Used only when `config.json` has no `apiKey` for a provider.

## Runtime settings

`~/.codexbar/linux-tray.json`:

```json
{
  "refreshSeconds": 120,
  "staleAfterRefreshes": 3,
  "iconName": "utilities-terminal"
}
```

- `refreshSeconds`: periodic refresh interval (minimum `30`).
- `staleAfterRefreshes`: stale threshold multiplier for status text.
- `iconName`: icon passed to `zenity --notification`.

## Tray backend

- Preferred backend: `zenity --notification --listen` for native tray presence.
- Fallback backend: stdout host (for headless/CI and environments without `zenity`).

## Current limitations

- Linux tray currently uses click-to-refresh with tooltip details.
- Provider toggles and advanced settings are still managed via `~/.codexbar/config.json`.
- `web/auto` provider source modes are downgraded to `cli` on Linux.
