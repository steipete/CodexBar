# CQuickJS

This SwiftPM C target vendors the minimal embeddable engine from
[quickjs-ng](https://github.com/quickjs-ng/quickjs) release `v0.15.1` (June 4, 2026). The source archive is
`https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.15.1.tar.gz` with SHA-256
`c4e813951b7c46845096a948e978c620b11ab4cf5fd622ca09c727ec31f42623`.

The target retains the four upstream engine translation units, 14 required headers, and the upstream MIT license: 19
vendored files totaling 2,694,082 bytes. It intentionally excludes the `qjs`/`qjsc` CLIs, REPL, libc modules, examples,
tests, and build-system files. The sources are unmodified; SwiftPM compile definitions and linker settings live in
`Package.swift`.

Run `Scripts/regenerate-quickjs-vendor.sh check` to verify the checked-in files or
`Scripts/regenerate-quickjs-vendor.sh write` to download, checksum, and re-stage them.
