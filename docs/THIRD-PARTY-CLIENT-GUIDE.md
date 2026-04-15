# Connecting Third-Party Clients to OpenClaw

## For Client/Dashboard/Tool Developers

This guide explains how to properly connect your application to an OpenClaw gateway. Whether you're building a custom dashboard, a mobile app, a hardware integration, or an LM management tool like CodexBar, this is the correct procedure.

## Requirements

1. Your client must authenticate with the gateway
2. State-changing operations require `operator.admin` scope
3. Config changes must go through the `config.patch` API (not file writes)
4. Auth token sync must go through the gateway (not direct file writes)

## Connection Flow

### 1. Read the Gateway Token

The gateway token is stored at `~/.openclaw/gateway.token` (permissions 0600, owner-only readable).

```python
# Python example
with open(os.path.expanduser("~/.openclaw/gateway.token")) as f:
    token = f.read().strip()
```

```swift
// Swift example
let tokenPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".openclaw/gateway.token")
let token = try String(contentsOf: tokenPath).trimmingCharacters(in: .whitespacesAndNewlines)
```

```javascript
// Node.js example
const token = fs.readFileSync(path.join(os.homedir(), '.openclaw/gateway.token'), 'utf8').trim();
```

### 2. Connect via WebSocket

```
ws://127.0.0.1:18789?token=<gateway-token>
```

For password-based gateways:
```
ws://127.0.0.1:18789?password=<gateway-password>
```

### 3. Send JSON-RPC Messages

OpenClaw uses JSON-RPC over WebSocket:

```json
// Request
{
  "type": "request",
  "id": "unique-uuid",
  "method": "config.get",
  "params": {}
}

// Response
{
  "type": "response",
  "id": "unique-uuid",
  "ok": true,
  "payload": { ... }
}
```

### 4. Read Current Config

```json
{
  "type": "request",
  "id": "1",
  "method": "config.get",
  "params": {}
}
```

Response includes `baseHash` needed for config.patch:
```json
{
  "type": "response",
  "id": "1",
  "ok": true,
  "payload": {
    "config": { ... },
    "baseHash": "sha256-hash-of-current-config"
  }
}
```

### 5. Modify Config (Requires operator.admin)

```json
{
  "type": "request",
  "id": "2",
  "method": "config.patch",
  "params": {
    "raw": "{\"models\":{\"providers\":{\"ollama\":{\"api\":\"ollama\",\"baseUrl\":\"http://127.0.0.1:11434\"}}}}",
    "baseHash": "sha256-hash-from-config-get"
  }
}
```

The `raw` field is a JSON merge-patch (RFC 7396). Only include the fields you want to change.

### 6. List Models

```json
{
  "type": "request",
  "id": "3",
  "method": "models.list",
  "params": {}
}
```

## What NOT to Do

### DO NOT write config files directly

```bash
# WRONG — triggers HMAC integrity warning, may be rejected
echo '{"models":...}' > ~/.openclaw/openclaw.json
```

### DO NOT kill the gateway process

```bash
# WRONG — unauthorized, no audit trail
kill -9 $(lsof -ti :18789)
```

The gateway restarts itself after `config.patch` if needed.

### DO NOT modify auth-profiles.json directly

```bash
# WRONG — bypasses authorization
echo '{"profiles":...}' > ~/.openclaw/agents/main/agent/auth-profiles.json
```

Use the `auth.profiles.sync` gateway method instead.

## Error Handling

| Error Code | Meaning |
|-----------|---------|
| `INVALID_REQUEST` | Missing required scope (need `operator.admin`) |
| `UNAVAILABLE` | Gateway still starting up |
| `CONFLICT` | baseHash mismatch (config changed since your last read) |

On `CONFLICT`, call `config.get` again to get the latest baseHash, then retry your patch.

## Device Registration (Advanced)

For persistent client identity, register as a device:

1. Generate an Ed25519 keypair
2. Include device identity in your connect message
3. User approves via `openclaw devices approve <device-id>`
4. Your client appears in OpenClaw's Devices section
5. User can manage/revoke access

See `src/infra/device-identity.ts` and `src/infra/device-pairing.ts` for the protocol details.

## Examples

### CodexBar (Swift)
- Reads gateway token from disk
- Connects via URLSessionWebSocketTask
- Uses config.get + config.patch for LM config injection
- Stores pairing state in macOS Keychain
- Source: `Sources/CodexBarCore/OpenClawIntegration/OpenClawGatewayClient.swift`

### Python Script
```python
import asyncio
import json
import websockets

async def inject_config():
    token = open(os.path.expanduser("~/.openclaw/gateway.token")).read().strip()
    async with websockets.connect(f"ws://127.0.0.1:18789?token={token}") as ws:
        # Get current config
        await ws.send(json.dumps({
            "type": "request", "id": "1", "method": "config.get", "params": {}
        }))
        resp = json.loads(await ws.recv())
        base_hash = resp["payload"]["baseHash"]
        
        # Patch config
        patch = {"models": {"providers": {"ollama": {"api": "ollama"}}}}
        await ws.send(json.dumps({
            "type": "request", "id": "2", "method": "config.patch",
            "params": {"raw": json.dumps(patch), "baseHash": base_hash}
        }))
        result = json.loads(await ws.recv())
        print(f"Patch result: {result['ok']}")

asyncio.run(inject_config())
```

## Upgrading Existing Clients

If your client previously used file writes to modify OpenClaw config:

1. **Replace file writes with `config.patch` RPC** — this is the main change
2. **Replace `kill -9` with letting the gateway restart itself** — config.patch handles this
3. **Add gateway token auth** — read from `~/.openclaw/gateway.token`
4. **Handle the HMAC integrity check** — your file writes will trigger warnings now

The migration is straightforward: read token → connect WebSocket → config.get → config.patch. That's it.
