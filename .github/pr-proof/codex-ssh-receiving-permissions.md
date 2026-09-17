# SSH receiving-permissions follow-up

Implementation: `2824852b8169b85102ce79a7884f39ac66d9f004`.

A field report exposed a gap in the initial synthetic fixture: source logs were group-readable (`0664`), whereas
that fixture used `0600`. macOS system openrsync retained group/other permissions for empty symbolic assignments
such as `Fgo=`. The local receiving-tree check correctly rejected the resulting broad modes, but its error text
incorrectly suggested only an unsupported server path or file type.

The fix retains `--perms` and changes only the clearing operations to explicit `Dgo-rwx` and `Fgo-rwx`. It does not
relax the required `0700` directory / `0600` file modes, create a persistent cache, change source permissions,
introduce in-place updates or change transfer completeness/size/count checks. Error wording now includes received
file permissions.

## Actual checks

All transferred data in these checks was generated synthetic JSONL under a dedicated temporary directory. No real
conversation bodies were used. Before/after transfer checks left the synthetic source contents and modes unchanged;
the remote temporary fixture was removed afterward.

| Synthetic source mode | Original flags, Mac receiver over SSH | Fixed flags, Mac receiver over SSH | Fixed flags, GNU receiver |
| --- | --- | --- | --- |
| `0444` | `0644` | `0600` | `0600` |
| `0644` | `0644` | `0600` | `0600` |
| `0664` | `0664` | `0600` | `0600` |
| `0777` | `0677` | `0600` | `0600` |

The Mac-to-Ubuntu ARM64 SSH probe also used the actual `CodexRemoteLogMirror`, production manifest validation and
production guardian entry point: all four files matched their known synthetic contents, arrived with mode `0600`, and the
request directory was empty after the consumer returned. A separate real GNU rsync receiving probe verified the
same flags without changing the remote source files.

The new portable regression uses the system rsync and actual guardian. It observes nonempty temporary files during
transfer and requires every observed file/directory mode to be private. Final assertions independently verify all
four source modes, received bytes, source bytes/modes, strict budgets and cleanup. A separate test rejects partial
staging before publication and checks cleanup. Sampling is not a claim to have observed every transient state.

An initial test incorrectly required sampling every temporary filename. A full-suite run exposed this race; the
test now gives one larger file a bounded observation interval, requires at least one nonempty temporary file and
leaves exhaustive four-file assertions to the final checks.

- Focused mirror/guardian/permission suites: 20 tests / 3 suites passed.
- `make check`: passed; existing repository lint reported zero violations.
- `make test`: 107/107 groups passed on the first attempt; test summaries report 11,149 tests; no failures, retries or timeouts.
- Independent read-only review of the production diff and corrected tests: passed.
- Actual Mac-to-Ubuntu SSH and GNU receiving probes: passed as above.

This is additional transport evidence. The [earlier native UI capture](codex-ssh-native-runtime.md) remains labeled
with its original `8f1df347` implementation. The full Linux Swift suite was not rerun for this follow-up; the GNU
receiving probe is not presented as a replacement for that suite. Real-history combined accounting remains subject
to the documented overlap, retained-history and pricing boundaries.
