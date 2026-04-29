# CodexBar + OpenClaw Setup Guide

## What is CodexBar?

CodexBar is an external LM (Language Model) provider manager for OpenClaw. It lets you:
- Manage multiple Codex, Claude, Gemini, and Ollama accounts in one place
- Set up fallback chains with drag-to-reorder
- Auto-rotate through accounts when one hits rate limits
- Inject your LM configuration into OpenClaw with one click
- Monitor Ollama models, VRAM usage, and cold-start status

## New Users — Setting Up from Scratch

### Step 1: Install OpenClaw

```bash
npm install -g openclaw@latest
```

### Step 2: Run Onboarding

```bash
openclaw onboard
```

When prompted for a model/auth provider, select **CodexBar (External LM Manager)**. This skips LM configuration — CodexBar will handle it after setup.

Complete the rest of onboarding normally (workspace, channels, etc.).

### Step 3: Note Your Gateway Token

After onboarding, your gateway token is stored at:
```
~/.openclaw/gateway.token
```

You'll need this to connect CodexBar. The token is also shown during `openclaw gateway run`.

### Step 4: Start the Gateway

```bash
openclaw gateway run
```

### Step 5: Install CodexBar

Download from the CodexBar releases page or build from source:
```bash
git clone <repo-url>
cd CodexBar-openclaw/CodexBar
swift build
# Install the app
```

### Step 6: Configure CodexBar

1. Open CodexBar from your menu bar
2. Sign into your LM providers (Codex accounts, Claude, Gemini, etc.)
3. Connect local Ollama if running

### Step 7: Connect CodexBar to OpenClaw

1. Open CodexBar → Preferences → **LM Hub** tab
2. Click **Inject to OpenClaw**
3. CodexBar reads your gateway token automatically
4. Selects the running gateway (port 18789 by default)
5. Injects your LM configuration via secure WebSocket API
6. Gateway restarts with your new config

### Step 8: Verify

Open your browser to `http://127.0.0.1:18789` and send a message. Your configured LM providers should respond.

---

## Existing Users — Adding CodexBar to Running OpenClaw

If you already have OpenClaw running with providers configured:

### Step 1: Install CodexBar

(Same as Step 5 above)

### Step 2: Sign into Providers in CodexBar

Add your Codex accounts, Ollama endpoints, etc.

### Step 3: Connect to OpenClaw

1. Open CodexBar → Preferences → **LM Hub** tab
2. CodexBar discovers running gateways on your machine
3. Click **Inject to OpenClaw**
4. CodexBar connects as a device using your gateway token
5. Your existing config is preserved — only LM sections are updated

### What Gets Updated

CodexBar only modifies these sections of your OpenClaw config:
- `models.providers` — your LM providers and models
- `agents.defaults.model` — fallback chain
- `auth.profiles` — provider auth (tokens, API keys)
- `auth.order` — account rotation order
- `plugins.entries.ollama` — Ollama plugin enablement

### What's Preserved

Everything else stays untouched:
- Gateway settings, channels, plugins (Discord, iMessage, etc.)
- Workspace, tools, hooks, skills
- Memory, dreaming, browser config
- MCP servers, custom agents

---

## Gateway Authentication

CodexBar supports all OpenClaw gateway auth modes:

### Token Auth (Default)
```
Gateway reads token from ~/.openclaw/gateway.token
CodexBar reads the same file automatically
```

### Password Auth
If your gateway uses password auth:
1. Open CodexBar → LM Hub → Gateway Settings
2. Enter the gateway password
3. CodexBar connects with password instead of token

### Tailscale Auth
For remote gateways on Tailscale:
1. Configure gateway with `gateway.bind: tailnet`
2. CodexBar connects via Tailscale IP
3. Auth uses Tailscale identity verification

---

## How Fallback Works

CodexBar configures your fallback chain as:

```
Primary Model (e.g. Codex gpt-5.4)
  → Account 1 (user1@example.com) — tries first
  → Account 2 (user2@example.com) — if account 1 at quota
  → Account 3 (user3@example.com) — if account 2 at quota
  → Account 4 ... — continues through all accounts
  ↓ ALL accounts exhausted
Local Fallback (e.g. Ollama gemma4:e4b)
  → Runs locally, no API needed, always available
```

**Key concepts:**
- Account rotation happens WITHIN a provider (not separate fallback entries)
- The fallback chain lists DIFFERENT providers (Codex → Claude → Gemini → Ollama)
- You can reorder providers and accounts in CodexBar's LM Hub

---

## Security

### How Injection Works (Secure)

```
CodexBar → reads gateway.token → connects via WebSocket
→ authenticates with token → sends config.patch RPC
→ gateway validates, applies, restarts itself
```

- **No file writes** — config changes go through the gateway API
- **No process killing** — gateway restarts itself via SIGUSR1
- **Token required** — can't inject without the gateway token
- **Audit logged** — all config changes are logged with actor identity

### Config Integrity

OpenClaw now includes HMAC integrity checking:
- Config writes are signed with HMAC-SHA256
- External modifications are detected and logged
- `openclaw security audit` shows integrity status

---

## Troubleshooting

### CodexBar can't find the gateway
- Make sure the gateway is running: `openclaw gateway run`
- Check the port: default is 18789
- CodexBar scans ports 18789-22789 automatically

### "Token not found" error
- Check `~/.openclaw/gateway.token` exists
- Verify permissions: `chmod 600 ~/.openclaw/gateway.token`
- The token is created during `openclaw onboard`

### Ollama models not responding
- Verify Ollama is running: `ollama ps`
- Check model is downloaded: `ollama list`
- First request may take 15-20s for cold start (model loading)

### Account rotation not working
- Check auth.order in config: all accounts should be listed
- Clear auth-state: CodexBar does this automatically on inject
- Verify tokens: open CodexBar → check account status indicators

### Config was modified outside the gateway
- This triggers an HMAC integrity warning
- Normal for manual config edits (not a security issue)
- Use `config.patch` API for programmatic changes
