# PR: Security Hardening + CodexBar External LM Manager Support

## Summary

This PR adds config integrity protection, scope enforcement for config writes, and onboarding support for CodexBar (an external LM provider manager).

## Security Changes

### Config HMAC Integrity (`src/config/io.hmac-integrity.ts`)
- Config writes are now signed with HMAC-SHA256 using the gateway token
- On config load, the signature is verified. External modifications trigger a warning
- Prevents silent config injection from unauthorized local processes

### Scope Enforcement on config.patch (`src/gateway/server-methods/config.ts`)
- `config.patch` now requires `operator.admin` scope
- Prevents unauthenticated clients from modifying config via the gateway API
- Explicitly added to `ADMIN_SCOPE` group in `method-scopes.ts`

### Config Audit Log (`src/config/config-audit.ts`)
- All config changes logged to `~/.openclaw/logs/config-audit.jsonl`
- Tracks: timestamp, actor (gateway vs filesystem), changed paths, hashes
- Provides forensic trail for security investigations

### Security Audit Enhancement (`src/security/audit.ts`)
- HMAC integrity mismatch flagged in `openclaw security audit`
- `allowInsecureAuth` flagged as warning (transport vs authorization distinction)

## CodexBar Onboarding Support

### New auth choice: "CodexBar" (`src/commands/auth-choice-options.static.ts`)
- Added "CodexBar (External LM Manager)" to onboarding provider list
- When selected, skips LM config with instructions to connect CodexBar after setup
- Non-breaking — existing providers and flows unchanged

### Setup wizard handler (`src/wizard/setup.ts`)
- `codexbar` auth choice shows setup instructions and skips model selection
- Users complete onboarding normally (workspace, gateway auth, channels)
- After setup, they connect CodexBar using their gateway token

## Files Changed

| File | Change |
|------|--------|
| `src/config/io.hmac-integrity.ts` | NEW — HMAC integrity module |
| `src/config/config-audit.ts` | NEW — Config audit logger |
| `src/config/io.ts` | HMAC verify on load, HMAC write on save, audit logging |
| `src/config/types.openclaw.ts` | `integrityWarning` field on ConfigFileSnapshot |
| `src/gateway/method-scopes.ts` | config.patch/set/apply in ADMIN_SCOPE |
| `src/gateway/server-methods/config.ts` | Scope enforcement check |
| `src/security/audit.ts` | HMAC mismatch finding |
| `src/commands/auth-choice-options.static.ts` | CodexBar option |
| `src/wizard/setup.ts` | CodexBar auth choice handler |
| `docs/security/config-protection.md` | NEW — Security documentation |

## Migration

- **Non-breaking** — all changes are additive
- HMAC sig file generated on first config write
- Existing configs work without sig file (warning-only, no rejection)
- CodexBar onboarding option is purely additive to the provider list

## Test Plan

- [ ] Config write generates `.sig` sidecar file
- [ ] Config load with mismatched sig triggers warning
- [ ] `config.patch` without `operator.admin` scope returns error
- [ ] Config audit log captures changes
- [ ] `openclaw onboard` shows CodexBar option
- [ ] Selecting CodexBar skips LM config
- [ ] Existing onboarding flows unchanged
