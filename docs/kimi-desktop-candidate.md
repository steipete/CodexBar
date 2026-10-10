---
summary: "Paired-build Kimi Desktop discovery candidate and credential scope requiring maintainer review."
read_when:
  - Reviewing Kimi Desktop Local Storage acquisition
---

# Kimi Desktop discovery candidate

This is a review candidate for #3536, not released Desktop support. Ordinary builds retain existing
provider resolution, plugin capabilities, browser discovery order and the SweetCookieKit pin.
An explicit paired-checkout development build connects the native importer to the strict reader.
The prerequisite current-record work is steipete/SweetCookieKit#24. Its best-effort entry API
still matches origins by host and may return records from incomplete reads; it is not used by
this candidate's strict credential interface.

## Proposed boundary

`KimiDesktopSessionDiscovery` accepts host-owned settings and home directory. It reads only Auto,
China, the primary `Library/Application Support/kimi-desktop/Local Storage/leveldb` directory,
and the exact Chromium raw key for `https://www.kimi.com` / `access_token`. Manual, Off,
International and cancellation fail before this new Local Storage discovery. Existing International
Desktop cookie behavior is preserved. No refresh tokens, profile partitions,
KimiCU paths, browser roots, arbitrary origins or plugin-provided paths are accepted.

The shared-reader candidate adds opt-in `readCurrentValue(forRawKey:in:)`, reusing upstream
manifest/sequence/tombstone traversal. It requires CURRENT and available live files, validates
record/block checksums and rejects incomplete reads, conflicting same-sequence records,
symlinks and observable before/after file changes. The strict path now opens every directory
component relative to a pinned descriptor with `O_DIRECTORY | O_NOFOLLOW`, and each regular file
with `openat(O_NOFOLLOW)`. Identity checks precede `pread`; no path-based data read or mmap is used.
Directory replacement cannot redirect reads into a symlink target. Descriptor ownership is bounded
to one discovery call, and all descriptors are closed on failure or completion.

The host resolves only its trusted home with POSIX `realpath` before appending the fixed profile
path. The reader preserves that physical path: Foundation standardization can rewrite
`/private/var` to the symlinked `/var` spelling on macOS. Profile components are never resolved
through symlinks; the descriptor walk still rejects them. Synthetic fixtures resolve only their
newly created temporary root and retain intentional symlinks below it for negative tests.

This is still not a LevelDB transaction: concurrent changes after the final checks and rename/restore
ABA sequences cannot all be excluded. Synthetic Linux race tests and independent review cover the
previous check/read symlink flaw; Darwin compilation and real Desktop lifecycle behavior remain
unverified. Existing best-effort callers are unchanged.

The policy accepts only a bounded Latin-1-marked bare JWT with an access type, exact `kimi.com`
audience, finite future numeric expiry and valid optional not-before date. It rejects wrappers,
refresh tokens, `alg=none`, malformed data and lookalike audiences. These checks do not verify a
signature or prove account validity. Claim compatibility still needs authorized real-account
validation; no token or real profile was used in cloud tests.

## Maintainer direction and remaining integration

The [maintainer's October 10 reply](https://github.com/steipete/CodexBar/issues/3536#issuecomment-6100068855)
accepts descriptor-anchored shared reads, `openat`/`O_NOFOLLOW`, Auto-only primary-profile discovery,
the exact access-token key and no historical-token scan. It requests a CodexBar PR against main
and assigns the dependency pin update (release or revision) to maintainers. Waiting for a release
is therefore not a contributor prerequisite. This does not grant plugins generic storage access.

SweetCookieKit #24 at `29e7af6bb71f1b624380ab556330e8be8f7ddd65` provides sequence-based current-record
selection, manifest live-file selection and tombstones through the existing best-effort public API.
It does **not** contain this candidate's `readCurrentValue(forRawKey:in:)`, mandatory complete reads,
checksum checks, or descriptor-anchored `O_NOFOLLOW` implementation. Those remain in the separate
six-file shared-reader proposal ending at `3ac0966ed4dba4fd26da9c49cd32d9c358d19515`.
Pinning #24 alone cannot compile the paired candidate's strict factory. Maintainers need that
additional reader change (or an equivalent upstream API) before ordinary-build activation.
The pin itself is intentionally left to maintainers. The paired checkout's Ego Lite scope overlay
is not part of the upstream reader proposal.

## Reproducible development build

Run `Scripts/test_kimi_desktop_candidate.sh /absolute/path/to/patched/SweetCookieKit build`
on macOS with Swift 6.2 or later. The script requires the exact reviewed clean dependency commit,
then sets `CODEXBAR_KIMI_DESKTOP_CANDIDATE_PATH` for that command only. Package.swift selects
that named local package and defines `CODEXBAR_KIMI_DESKTOP_CANDIDATE` in CodexBarCore.
A missing package fails immediately; an older reader fails compilation instead of silently falling
back to 0.5.5. The script builds Core only; it does not install or launch an app or make an API call.
The `test` action first runs the two strict-reader suites, then sets `CODEXBAR_KIMI_CORE_TESTS=1`
to run the repository-owned isolated SwiftPM graph. This graph compiles the actual Core and CLI
sources and selected synthetic tests in place, excluding App and Widget targets and their asset
catalogs. It needs no `actool`; it is not a temporary source-copy workaround. It includes default
temporary-directory and physical-home success, profile-symlink rejection, logout, policy and
monthly CLI/parser regression cases. Keychain and session isolation flags remain enabled.
`reader-test` runs just the dependency suites. Optional `full-test` uses the normal app-dependent
graph and requires full Xcode/`actool`; the script never installs tools.

The verification script requires the independently reviewable SweetCookieKit branch at
`3ac0966ed4dba4fd26da9c49cd32d9c358d19515`, without the historical paired build's browser-scope
preservation overlay. The older paired revision `3166b1cba5f77dce2e1fde575c05789e1f7a3ff9`
has identical strict reader and tests but is retained only as earlier evidence. Do not submit
its unrelated overlay as part of the reader fix. The dependency's browser catalog remains
upstream-owned; this new credential path still accepts only the fixed Kimi Desktop profile.

In this build, both native Web strategy and API/CLI enrichment reach the existing Auto-gated
`KimiCookieImporter.desktopAuthToken`, then the strict factory. China strict nil is authoritative:
there is no historical Desktop cookie fallback. Existing browser/environment fallback remains
subject to the original source policy. International retains only its existing cookie path.
There is no plugin capability or runtime environment switch for credential discovery.

This isolates the unpublished strict dependency for review; it does not enable ordinary builds.
After the strict API is available, ordinary-build activation must accompany the maintainer-owned
pin update. Native synthetic acceptance remains pending. The contributor has authorized a draft
PR after independent review despite unavailable Mac testing; this does not make the missing
native or real-account checks pass.

## Verification limits

Linux tests exercise the actual policy, native selection seam and `KimiWebFetchStrategy`, including
the real HTTP request builder/parser against an in-memory transport, without networking.
A separate reproducible source-copy harness exercises the shared reader and policy using only
synthetic LevelDB files; portability edits change platform guards, Darwin imports and stat field
names. This does not compile or test native macOS integration, AppKit rendering, keychain access,
Desktop lifecycle/sign-out behavior, signature validity, API acceptance or the user's installed app.
