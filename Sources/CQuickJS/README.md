# CQuickJS

This SwiftPM C target vendors the minimal embeddable engine from
[quickjs-ng](https://github.com/quickjs-ng/quickjs) release `v0.17.0` (September 18, 2026). The source archive is
`https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz` with SHA-256
`559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9`.

The target retains the four upstream engine translation units, 14 required headers, and the upstream MIT license: 19
vendored files totaling 2,826,859 bytes. It intentionally excludes the `qjs`/`qjsc` CLIs, REPL, libc modules, examples,
tests, and build-system files. The sources are unmodified; SwiftPM compile definitions and linker settings live in
`Package.swift`.

Run `Scripts/regenerate-quickjs-vendor.sh check` to verify the checked-in files or
`Scripts/regenerate-quickjs-vendor.sh write` to download, checksum, and re-stage them.
