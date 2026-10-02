# Langdock acceptance status

Recorded on October 1, 2026. Provider code tested: `e2af20453c514aabb265b143d7af623170de648a`.
The acceptance documentation added after this commit does not change the provider or test code.

## Automated verification

- `make test`: all 1,477 selections across 133 groups passed on the first attempt; no failures,
  timeouts, or isolated retries. Total duration: 1,314 seconds.
- `make check`: passed, including strict SwiftLint with zero violations.
- After the controlled attempt, `./Scripts/test_fast.sh --filter Langdock` and `make check` passed
  again without live account probes. The provider code remained unchanged.
- Contribution history secret scan and `git diff --check`: passed.
- Synthetic production-view rendering is described in [README.md](README.md). It does not establish
  live authentication, profile isolation, or visible publication from a packaged app.

## Packaged builds

Both bundles were packaged from the same provider commit on macOS 27.0.1 arm64 with Apple Swift 6.4,
using the repository's debug packaging and ad hoc signing. Both signatures passed
`codesign --verify --deep --strict`. Bundle identifier: `com.steipete.codexbar.debug`.
Both use the existing debug application-group entitlement.

| Variant | `get-task-allow` | Code directory hash |
| --- | --- | --- |
| Debugger bundle | Present, true | `27e9f9aef206cbbb9bc3753a9b455f240961c40e` |
| Normal debug bundle | Absent | `4d3c09ee5c90012cfb916543150d05721b4246e3` |

Executable SHA-256:

- Debugger bundle: `bcc69fc51bd7afa77b187b43e3fb1929a6687976b2ce82131d118cdc10e7fead`.
- Normal debug bundle: `6e92df48f372d6228d7de2dcf1d84cf1e6002b4b4a42a95378c4c34e7f657b45`.

## Controlled host attempt and recovery

This was a controlled test on the user's Mac. `CODEXBAR_CONFIG` separated only the JSON config;
shared defaults, app-group data, and startup filesystem effects were inventoried separately.

- Credential and app-group migrations were already complete. Sync, login-item registration, and
  file logging were checked before launch. There were no user-plugin source files in the configured
  plugin directory. Only Langdock was enabled in the temporary config.
- Private backups and a change journal were kept outside the repository with restricted permissions.
  Token-cost scans were temporarily disabled and the refresh interval set to manual.
- The exact debugger-bundle executable was observed running. Test-environment flags were absent;
  the temporary config environment variable was present. LLDB attached without privilege escalation
  and detached again. No credentials, session fingerprints, HTTP payloads, or debugger replacement values
  were used as evidence.
- Computer use could not bind the test app's exact path, returning a timeout. Selecting its bundle ID
  was ambiguous because the preserved working Langdock bundle has the same ID. The same computer-use
  timeout also occurred with the original installed app after recovery. This is a tool blocker; it
  does not establish a TCC denial, an authentication failure, or a missing status item.
- Visible Langdock publication and a successful real-provider request were not established.
  Therefore no disposable Edge profile or session-destructive test was started. The normal debug
  bundle was built and verified, but its live fetch/restart acceptance remains open.
- An `EXIT/INT/TERM` recovery handler stopped the exact test process, restored four owned preference
  deltas, checked the resulting debug defaults against their baseline, and restarted the original
  installed app by its exact path. The test process and supervisor exited; the owned temporary
  cookie-copy directory was empty. No shared data file required restoration.
- No new permission grants, permission resets, Safe Storage changes, autostart changes, or Langdock
  desktop-app changes were made. The user's working Langdock bundle remained unchanged.
- The owned test bundle and its LaunchServices registration were removed. Nine identified artifacts
  from preceding Langdock work were removed, including duplicate synthetic images whose committed
  copies were verified. Final private-backup removal and recoverable worktree archival are reported
  separately in the PR conversation after verification; existing user files are preserved.

## Remaining live acceptance

These cases must be observed through the real selected-profile importer and request path at the
provider revision being submitted. Parser fixtures and injected cookie readers remain supplemental.

| Case | Required observation |
| --- | --- |
| Personal usage | Selected-profile import, successful parsing, and visible publication; timestamped web comparison. |
| Refresh and restart | Repeated refreshes and restart of the same identified bundle. |
| No profile fallback | Another valid profile remains signed in; an absent or signed-out selected disposable profile supplies no borrowed values. An access error is inconclusive. |
| Session no longer verifiable | After HTTP and before revalidation, clear Langdock site data only in the disposable profile; discard the response and old bars. |
| Session actually changed | Separate re-login at that boundary; observe the real `sessionChanged` result and discarded values. Cookie deletion alone does not prove this case. |
| Recovery | Normal sign-in and refresh publish current selected-profile values again. |
| Normal debug signature | Repeat successful fetch and restart with `get-task-allow` absent. |

Before another attempt, repeat the host inventory and per-change recovery journal. Create the
disposable profile through Edge without sync or import. Do not publish cookie values, fingerprints,
account details, or raw responses. Do not obtain new access without a concrete recovery route.
Keep the original app available; stop only identified test processes. On success, failure, or abort,
remove the disposable profile and owned diagnostics, restore only owned settings/files, preserve
concurrent user changes, and verify the original app before removing recovery backups.
Local deletion does not prove server-side session revocation; macOS audit logs are not claimed erased.

## Maintainer decisions

- Explicit `VISION.md` approval is still required for the native exact-store browser-host entry point
  and its profile/session ownership contract.
- Contributor CI requires maintainer approval. The run for the provider commit reports
  `action_required` with no jobs started; GitGuardian passed. The workflow defers macOS test shards
  while the PR is a draft. Full CI must be checked at the final PR head after acceptance and
  `Ready for review`.
- The PR remains a draft until the contributor's live acceptance and local cleanup are complete.
