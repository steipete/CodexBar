# Claude history artifact writes

PR #4396 partially addresses #3882: changing a transcript previously streamed complete cache and report-memo JSON into fresh temporary files. Fragment reuse reduced encoding work, not submitted output bytes. The replacement clones the previous inode on supported macOS volumes, compares bounded blocks at the same offsets, writes differences, truncates old suffixes, and retains atomic rename. Linux and unsupported volumes use the same writer without cloning.

The paired workload retains 24,000 synthetic rows and appends one row twelve times. It compares daily, hourly, and quota-slice reports after every append and after cold reload. The regression requires at least 50% fewer submitted bytes on a clone-capable volume; there are no wall-clock assertions. On current main (`e8013e28f4b`), with only byte-count instrumentation added to the existing `fwrite` path, the two runs submitted 89,073,681 and 89,073,680 bytes and failed that budget assertion. Report equality checks passed.

The maintainer rerun measured 89,073,681 → 34,873,441 submitted bytes in the scanner regression (60.85% less); all 216 focused tests passed. Independent CLI processes measured 89,076,078 → 34,875,708 bytes with 24 clones, matching reports after every append, and zero writes on cold reload. All four injected clone errors exercised full-write fallback; partial-write failure preserved committed artifacts, removed temporary output, and recovered on the next process. These results reproduce the contributor's approximately 89.1 MB → 34.9 MB measurement.

These are submitted writer bytes, including private temporary output, not physical APFS writes, disk wear, or a CPU improvement. Changes in serialized length still shift and rewrite large suffixes. Full serialization, hashing, and block comparison remain; this does not close #3882.

## Reproduce

Run the scanner regression with the repository's scrubbed test environment:

```sh
source Scripts/test_environment.sh
swift test --build-system native --jobs 4 -Xswiftc -gnone \
  --filter 'CostUsageClaudeArtifactWriterTests|CostUsageClaudeWriteAmplificationTests'
```

For independent CLI processes on macOS, use a debug CLI built with those same native-backend flags:

```sh
python3 docs/research/fixtures/claude-artifact-cli-proof.py \
  --binary .build/debug/CodexBarCLI \
  --output /tmp/codexbar-cli-write-proof-new
```

The output directory must be new. The script compiles the adjacent C DYLD observer with system Clang and retains synthetic fixtures and result JSON there. It supplies a fresh environment with isolated home, configuration, transcript, and cache paths, suppressing Keychain access. It never starts the GUI or reads a real account.

The observer counts successful `pwrite` bytes only for private Claude artifact files. It forces `fclonefileat` errors to exercise full-write fallback for `EXDEV`, `ENOTSUP`, `EROFS`, and `ENOSPC`. It also allows 64 bytes of private output before injecting persistent `ENOSPC`: committed artifacts must remain byte-identical, temporary files must disappear, and a subsequent clean process must recover the same report. Injected clone errors on a writable volume test fallback dispatch; they do not imply writes can succeed on an actually full or read-only volume.

## Persistence guarantees

The source inode is pinned through cloning and source symlinks are not followed. A successful clone is opened privately and normalized to mode 0600. The macOS `clonefile(2)` contract is atomic: failure creates no destination, so exclusive creation can safely attempt the full-write fallback. If creating or writing private output also fails, the previous artifact is preserved. The caller removes temporary files on success, failure, and cancellation.

Neither the previous `fflush` path nor the new unbuffered `pwrite` path calls `fsync`; this preserves atomic replacement, not a new power-loss durability guarantee. JSON schemas, keys, filenames, provider scopes, and report-window isolation remain unchanged. Cloned extended attributes are inherited. Same-user malicious interference with the private cache directory remains outside this cache's threat model.

Cache metrics, fixture isolation, and test eviction helpers live in the test target. Core retains only task-local observation hooks and internal cache types, preserving the existing test API without shipping recorder orchestration in the core target.
