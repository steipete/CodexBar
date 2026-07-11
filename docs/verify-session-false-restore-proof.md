# Verification: Codex session false-restore OS notification bug

Reproduces and verifies the fix for Codex session OS notifications posting `.restored`
when OAuth briefly returns `usedPercent = 0` while `resetsAt` is unchanged.

## Scope

1. Synthetic unit repro with issue #2054 fixture shape.
2. Contract test that passes once the bug is fixed.
3. Real Codex usage fetch through CodexBarCLI (redacted).
4. Replay of live `sessionResetsAt` through both celebration and session notification paths.

## Command

```bash
./Scripts/verify_session_false_restore_live.sh
```

## Redacted live proof (2026-07-11T11:50Z)

```text
[verify-session-false-restore] PROOF_LIVE_FETCH sessionUsed=100.0 sessionResetsAt=2026-07-11T12:36:22Z weeklyUsed=22.0 weeklyResetsAt=2026-07-18T07:36:22Z loginMethod=plus account=<redacted-email>
[verify-session-false-restore] PROOF_CELEBRATION_SUPPRESSED_TRANSIENT_ZERO events=0 sessionResetsAt=2026-07-11T12:36:22Z
[verify-session-false-restore] PROOF_SESSION_NOTIFICATION_SUPPRESSED_TRANSIENT_ZERO transitions=depleted sessionResetsAt=2026-07-11T12:36:22Z liveSessionUsedAtFetch=100.0
[verify-session-false-restore] PROOF_API_FLICKER_SUPPRESSED transitions=depleted
```

## Redacted live fetch summary

```json
{
  "provider": "codex",
  "source": "oauth",
  "account": "<redacted-email>",
  "sessionUsedPercent": 100,
  "sessionResetsAt": "2026-07-11T12:36:22Z",
  "weeklyUsedPercent": 22,
  "weeklyResetsAt": "2026-07-18T07:36:22Z",
  "loginMethod": "plus"
}
```

## Unit repro summary

```text
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:2026-07-11T19:49:38+0800 info com.steipete.codexbar.sessionQuota: [CodexBarCore] transition depleted: provider=codex prev=80.0 curr=0.0
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:2026-07-11T19:49:38+0800 info com.steipete.codexbar.sessionQuota: [CodexBarCore] transition depleted: provider=codex prev=80.0 curr=0.0
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:2026-07-11T19:49:38+0800 info com.steipete.codexbar.sessionQuota: [CodexBarCore] transition restored: provider=codex prev=0.0 curr=100.0
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test "api flicker depleted transient zero then depleted again posts once" passed after 0.052 seconds.
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test "contract real session reset with advanced resetsAt should still notify restored" passed after 0.052 seconds.
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:2026-07-11T19:49:38+0800 info com.steipete.codexbar.sessionQuota: [CodexBarCore] transition depleted: provider=codex prev=80.0 curr=0.0
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:2026-07-11T19:49:38+0800 info com.steipete.codexbar.sessionQuota: [CodexBarCore] transition depleted: provider=codex prev=50.0 curr=0.0
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:2026-07-11T19:49:38+0800 info com.steipete.codexbar.sessionQuota: [CodexBarCore] transition depleted: provider=codex prev=80.0 curr=0.0
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test "session notification suppresses restored on codex transient zero" passed after 0.096 seconds.
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test "contract true depletion while working still posts depleted once" passed after 0.097 seconds.
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test "contract session notification must not post restored on codex transient zero" passed after 0.097 seconds.
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test "depleted notification copy is the expected user facing message" passed after 0.097 seconds.
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test "control celebration path suppresses codex session transient zero" passed after 0.100 seconds.
/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T//codexbar-session-false-restore.wB4ZUE/unit-repro.log:✔ Test run with 8 tests in 1 suite passed after 0.100 seconds.
```
