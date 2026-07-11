# Verification: Codex weekly reset confetti boundary guard

Verification artifact for https://github.com/steipete/CodexBar/pull/2056, related to https://github.com/steipete/CodexBar/issues/2054.

## Scope

Demonstrate after-fix Codex weekly confetti behavior with:

1. A real Codex usage fetch through CodexBarCLI (redacted).
2. Replay of the live weekly `resetsAt` through the fixed weekly reset detector.
3. Suppression for unchanged and missing weekly boundaries.
4. Exactly one celebration after a genuine weekly boundary advance.

## Command

```bash
./Scripts/verify_2054_live.sh
```

Optional: build the packaged app from this branch before fetching:

```bash
CODEXBAR_SKIP_PACKAGE=0 ./Scripts/verify_2054_live.sh
```

## Redacted live proof (2026-07-11T10:01Z)

```text
[verify-2054-proof] PROOF_LIVE_FETCH weeklyUsed=2.0 weeklyResetsAt=2026-07-18T07:56:55Z loginMethod=plus account=<redacted-email>
[verify-2054-proof] PROOF_SUPPRESSED_TRANSIENT_ZERO events=0 weeklyResetsAt=2026-07-18T07:56:55Z
[verify-2054-proof] PROOF_SUPPRESSED_NIL_BOUNDARY events=0
[verify-2054-proof] PROOF_CELEBRATED_REAL_RESET events=1 previousWeeklyResetsAt=2026-07-18T07:56:55Z advancedWeeklyResetsAt=2026-07-25T07:56:55Z
```

## Redacted live fetch summary

```json
{
  "provider": "codex",
  "source": "oauth",
  "account": "<redacted-email>",
  "weeklyUsedPercent": 2,
  "weeklyResetsAt": "2026-07-18T07:56:55Z",
  "sessionUsedPercent": 12,
  "sessionResetsAt": "2026-07-11T12:56:55Z",
  "loginMethod": "plus"
}
```
