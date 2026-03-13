# CodexBar Chrome Extension (MVP)

Quick usage monitor for CodexBar without opening terminal.

## Features
- Popup summary: used, limit, utilization, provider/model counts
- Top model usage table
- Range switch: daily/weekly/monthly
- Settings page (bridge URL + alert threshold)
- Background alert check every 15 minutes

## Setup (lowest friction)
1. Start local bridge on your Mac:

```bash
cd /path/to/CodexBar
python3 Scripts/usage_api_server.py --port 8787 --binary "swift run CodexBarCLI"
```

2. Load extension in Chrome:
- `chrome://extensions`
- enable **Developer mode**
- **Load unpacked** → select `Extensions/CodexBarChrome`

3. Pin extension and open popup.

No sign-in required.

## Notes
- If popup says `runtime_missing`, install/ensure Swift + CodexBar runtime where bridge runs.
- If bridge is on another host, set URL in extension options.
