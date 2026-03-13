# CodexBar Chrome Extension — Mac Setup

## 1) Clone your fork and checkout branch

```bash
git clone https://github.com/anudeepadi/CodexBar.git
cd CodexBar
git checkout fix/codex-api-key-credentials
git pull --ff-only
```

## 2) Start local usage bridge (one command)

```bash
./Scripts/start-bridge.command
```

You should see:
- `CodexBar usage API running on http://127.0.0.1:8787`

Health check:
```bash
curl http://127.0.0.1:8787/healthz
```

## 3) Load extension in Chrome

1. Open `chrome://extensions`
2. Enable **Developer mode**
3. Click **Load unpacked**
4. Select folder: `Extensions/CodexBarChrome`
5. Pin extension to toolbar

## 4) First run (frictionless)

- Open extension popup
- It auto-detects bridge URL (`127.0.0.1` / `localhost`)
- Choose range and click Refresh

## 5) Optional settings

In extension Settings:
- Bridge URL (if non-default)
- Utilization alert threshold

## What you get

- Summary endpoint: `/api/usage/summary`
- Models endpoint: `/api/usage/models`
- Providers endpoint: `/api/usage/providers`
- Timeseries endpoint: `/api/usage/timeseries`
- Badge states: `OK` / `MID` / `HIGH` / `OFF`
