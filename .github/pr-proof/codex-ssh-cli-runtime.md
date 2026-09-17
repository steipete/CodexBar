# SSH Codex cost CLI: captured runtime evidence

> Historical v1 evidence. The integrated native UI revision replaces these unmerged CLI flags and summary transport. These earlier captures do not validate the v2 raw-log collection, combined accounting, or native interface.

Tested implementation: [`761afe3b9fa21f5abe2c7bb01a90faf8f1779656`](https://github.com/steipete/CodexBar/commit/761afe3b9fa21f5abe2c7bb01a90faf8f1779656).
Capture date: 2026-09-16 UTC. This evidence-only follow-up preserves the tested source and tests.

[Complete captured reports and provenance](codex-ssh-cli-runtime.json) include success, real disconnection/reconnection, controlled invalid-response cases, and signal cleanup diagnostics. The values below come from the saved runs of this PR's implementation. No screenshots or runtime results from other PRs are used.

## Setup and provenance

- Client: macOS 27.0 / arm64 / Swift 6.3.2, running the built `CodexBarCLI` and its production `/usr/bin/ssh` transport.
- Endpoint: Debian 12 / x86_64 / Swift 6.3.3 inside a temporary container on another Intel Mac, reached through an existing SSH jump host. This is a cross-machine Mac-to-Linux-container run.
- Both hosts scanned synthetic native Codex JSONL through the normal scanner and used independent synthetic pricing caches. No real Codex histories or provider credentials were used. The tiny dollar amounts are fixture results, not billing or provider price claims.
- The clean local checkout's HEAD, retained Swift compiler metadata, the remote archive's Git commit ID, and both executable SHA-256 values are recorded in the JSON artifact. The local OS/architecture were also rechecked read-only during publication; this is labeled separately from the earlier run. The harness's `sourceCommit` field alone is not treated as a runtime remote revision probe.
- JSON stdout was parsed by the original harness and is pretty-printed here; numbers, timestamps, source labels, and errors are unchanged. The text output and signal result objects are copied as recorded. This is a presentation of saved evidence, not a newly executed or byte-for-byte shell transcript.

In the command display, `$CLI` replaces the private absolute path to the built local executable. `codexbar-linux-test` is the disposable SSH alias used in the run, not a production host identity. Non-signal exit codes below are the original harness's successful subprocess-exit assertions, rather than a separately retained shell `$?` capture.

## Both sources succeed

```sh
"$CLI" cost --provider codex --remote codexbar-linux-test --days 7 --refresh --format json
```

Asserted exit code: `0`. Captured JSON stdout:

```json
[
  {
    "summary": {
      "sessionTokens": 110,
      "last30DaysTokens": 110,
      "coverage": {
        "estimated": 0,
        "priced": 1,
        "unmetered": 0,
        "unpriced": 0
      },
      "sessionCostUSD": 0.000366,
      "last30DaysCostUSD": 0.000366,
      "historyCoverageIsEstablished": true,
      "bucketTimeZone": "Asia/Shanghai",
      "historyDays": 7,
      "provider": "codex",
      "updatedAt": "2026-09-16T12:19:09Z",
      "provenance": "listPriceEstimate",
      "currencyCode": "USD"
    },
    "host": "local",
    "source": "local"
  },
  {
    "summary": {
      "sessionTokens": 220,
      "last30DaysTokens": 220,
      "coverage": {
        "estimated": 0,
        "priced": 1,
        "unmetered": 0,
        "unpriced": 0
      },
      "sessionCostUSD": 0.001464,
      "last30DaysCostUSD": 0.001464,
      "historyCoverageIsEstablished": true,
      "bucketTimeZone": "Etc/UTC",
      "historyDays": 7,
      "provider": "codex",
      "updatedAt": "2026-09-16T12:19:10Z",
      "provenance": "listPriceEstimate",
      "currencyCode": "USD"
    },
    "host": "codexbar-linux-test",
    "source": "ssh"
  }
]
```

This shows 110 local tokens and 220 remote tokens, separate `Asia/Shanghai` and `Etc/UTC` day boundaries, and the two source snapshot timestamps. There is no combined total. The text-mode capture is also retained in the JSON artifact; its currency formatter rounds these deliberately small amounts to `$0.00`, while JSON retains the full values.

## Remote unavailable; local result retained

The isolated remote container was stopped, then the same CLI command was issued. Asserted exit code: `1`. Captured JSON stdout:

```json
[
  {
    "source": "local",
    "host": "local",
    "summary": {
      "sessionTokens": 110,
      "last30DaysTokens": 110,
      "updatedAt": "2026-09-16T12:20:19Z",
      "currencyCode": "USD",
      "provider": "codex",
      "last30DaysCostUSD": 0.000366,
      "historyCoverageIsEstablished": true,
      "provenance": "listPriceEstimate",
      "sessionCostUSD": 0.000366,
      "coverage": {
        "estimated": 0,
        "priced": 1,
        "unmetered": 0,
        "unpriced": 0
      },
      "historyDays": 7,
      "bucketTimeZone": "Asia/Shanghai"
    }
  },
  {
    "source": "ssh",
    "host": "codexbar-linux-test",
    "error": "Could not read remote Codex costs. Check SSH and that the remote CLI supports --summary-only."
  }
]
```

After restarting the same container, the next query asserted exit `0` and returned 220 remote tokens again. Its complete output is under `reconnectedQuery` in the artifact. Controlled banner/unsupported-flag/oversized-output cases are explicitly distinguished from this real disconnected-endpoint check.

## Local SSH-child cleanup on terminal signals

For each signal, the harness ran the actual CLI against a delayed test command over SSH, discovered its direct local `ssh` child PIDs, sent the signal to the CLI, awaited CLI exit, and checked that those local children no longer existed. Captured diagnostic objects:

```json
[
  {
    "signal": "SIGINT",
    "exitCode": 1,
    "localSSHReaped": true
  },
  {
    "signal": "SIGTERM",
    "exitCode": 1,
    "localSSHReaped": true
  },
  {
    "signal": "SIGHUP",
    "exitCode": 1,
    "localSSHReaped": true
  }
]
```

The underlying PID list and `ps` output were not retained; these are the recorded results of the harness's process checks. They establish local SSH-child cleanup, not termination of every process on the remote host.

## Remaining owner decision

The runtime evidence addresses the proof request in [the automated review](https://github.com/steipete/CodexBar/pull/3687#issuecomment-5697461804). Product sign-off for the single-host, CLI-only, separate-report scope remains a maintainer decision. This artifact does not grant that approval or claim the PR is merge-ready.
