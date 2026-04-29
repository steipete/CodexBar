# Connecting Clients to OpenClaw — Security Guide

## Overview

Every client that connects to an OpenClaw gateway must authenticate properly. This document explains the correct procedure for connecting any client — whether it's a custom dashboard, a mobile app, a hardware device, or a tool like CodexBar.

## Core Principle

**Every client must be registered as a paired device or node with the gateway.** Unpaired clients can only perform read-only operations (health check, model listing). All state-changing operations (sending messages, modifying config, syncing auth) require proper pairing.

## How Authentication Works

OpenClaw uses two separate concepts:

1. **Transport Security** (`allowInsecureAuth`)
   - Controls whether HTTP (non-HTTPS) connections are allowed
   - Set to `true` for devices that can't do TLS (like Rabbit R1)
   - This is about the connection protocol, NOT authorization

2. **Authorization** (gateway token + device pairing)
   - Controls WHO can make changes
   - Gateway token is stored at `~/.openclaw/gateway.token` (permissions 0600)
   - Device pairing uses Ed25519 cryptographic identity
   - Required for ALL state-changing operations, regardless of transport

## Client Connection Procedure

### Step 1: Read the Gateway Token

The gateway token is at `~/.openclaw/gateway.token`. This file has restricted permissions (0600 — only the owning user can read it).

```
# Read the token
cat ~/.openclaw/gateway.token
```

Your client must be able to read this file. If running as a different user, the connection will fail (by design).

### Step 2: Connect via WebSocket

Connect to the gateway's WebSocket endpoint:

```
ws://127.0.0.1:18789  (loopback)
wss://your-host:18789  (remote, requires TLS)
```

### Step 3: Authenticate

Send a connect message with your client identity and the gateway token:

```json
{
  "type": "connect",
  "client": {
    "id": "your-client-id",
    "name": "Your Client Name",
    "version": "1.0.0",
    "platform": "macos"
  },
  "auth": {
    "mode": "token",
    "token": "<gateway-token>"
  }
}
```

### Step 4: Device Pairing (First Time)

If your client hasn't been paired before:

1. Generate an Ed25519 keypair for your client's identity
2. Include it in the connect message
3. The gateway creates a pending pairing request
4. The user approves via OpenClaw UI or CLI: `openclaw devices approve <device-id>`
5. Your client receives a device token with scopes
6. Store this token securely (Keychain on macOS, encrypted storage on other platforms)

### Step 5: Make API Calls

After authentication, you can call gateway methods:

```json
{
  "type": "request",
  "id": "<uuid>",
  "method": "config.patch",
  "params": {
    "raw": "{...}",
    "baseHash": "<from config.get>"
  }
}
```

## Method Scopes

| Method | Required Scope | Description |
|--------|---------------|-------------|
| `config.get` | `operator.read` | Read current config |
| `config.patch` | `operator.admin` | Modify config |
| `auth.profiles.sync` | `operator.admin` | Sync auth tokens |
| `models.list` | none | List available models |
| `chat.send` | `operator.write` | Send a message |
| `health` | none | Health check |

## What NOT to Do

### DO NOT: Write config files directly

```bash
# WRONG — bypasses all security
echo '{"models": {...}}' > ~/.openclaw/openclaw.json
```

This will trigger a config integrity warning and may be rejected by the gateway.

### DO NOT: Kill the gateway process

```bash
# WRONG — unauthorized restart
kill -9 $(lsof -ti :18789)
```

Use the gateway's own restart mechanism via `config.patch` (which triggers SIGUSR1 internally).

### DO NOT: Modify auth-profiles.json directly

```bash
# WRONG — bypasses authorization
echo '{"profiles": {...}}' > ~/.openclaw/agents/main/agent/auth-profiles.json
```

Use the `auth.profiles.sync` gateway method instead.

## For Third-Party Client Developers

If you're building a client, dashboard, or tool that connects to OpenClaw:

1. **Register as a device** — your app should go through device pairing on first connection
2. **Store identity securely** — use the platform's keychain/secure storage
3. **Use gateway API** — never write files directly
4. **Request only needed scopes** — don't request `operator.admin` if you only need `operator.read`
5. **Handle revocation** — if the user revokes your device, handle the disconnect gracefully

## For Existing Clients After Upgrade

If you previously connected to OpenClaw without proper device pairing:

1. Your client may stop working for state-changing operations
2. You need to add device pairing to your connection flow
3. The gateway token (which you may already use) is sufficient for initial auth
4. After pairing, your device appears in OpenClaw's Devices section

## CodexBar Example

CodexBar connects to OpenClaw as a paired device:

1. Reads `~/.openclaw/gateway.token`
2. Connects via WebSocket to the discovered gateway port
3. Registers as device "CodexBar LM Hub" with Ed25519 identity
4. User approves once in OpenClaw UI
5. Uses `config.patch` for config injection (not file writes)
6. Uses `auth.profiles.sync` for token sync
7. Appears in OpenClaw Devices section — user can manage/revoke access

## FAQ

**Q: Can I still manually edit openclaw.json?**
A: Yes, but the gateway will detect the change and log a security warning. For development/debugging, this is fine. In production, use `config.patch`.

**Q: What if I need `allowInsecureAuth`?**
A: That's fine — it only affects transport (HTTP vs HTTPS). Authorization (gateway token) is still required for all write operations.

**Q: Does this affect the OpenClaw mobile app?**
A: No — the mobile app already connects as a paired device.

**Q: What about the CLI?**
A: The CLI uses the gateway token automatically. No changes needed.
