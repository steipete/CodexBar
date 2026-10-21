---
summary: "Bundled open-source notices and how to refresh their pinned sources."
read_when:
  - Auditing bundled third-party resources and their licenses
  - Updating SwiftPM dependencies or vendored JavaScript
---

# Third-party notices

Settings → About → Acknowledgements displays the full notices bundled in
`Sources/CodexBarCore/Resources/Acknowledgements.json`. This generated resource ships with the app,
widget and CLI. CLI and Linux desktop release archives also carry a readable `THIRD_PARTY_NOTICES` file.
The desktop links system Qt libraries; it does not bundle Qt.

This inventory covers SwiftPM and the vendored application sources. The static Linux SDK also
embeds runtime libraries outside Package.resolved. Its upstream archive currently contains no
license files; completing that runtime inventory and pinned-source notice collection remains
necessary before treating the static distribution as fully covered.

Refresh notices after changing either root or widget `Package.resolved`:

```sh
python3 Scripts/acknowledgements.py --write
python3 Scripts/acknowledgements.py --verify-upstream
```

The generator reads immutable revisions from both lockfiles, retrieves exact LICENSE and NOTICE files,
and keeps their text and SHA-256 hashes. It includes Sparkle's external notices and ed25519 license,
Swift Crypto's BoringSSL/Fiat and XKCP notices for Linux, and every distinct copyright/permission header
in vendored QuickJS, including the Unicode tables. QuickJS is quickjs-ng 0.17.0; see
`Sources/CQuickJS/README.md` for its source archive and checksum.

Sucrase 3.35.1 bundles seven npm packages: Sucrase, `@jridgewell/gen-mapping`,
`@jridgewell/resolve-uri`, `@jridgewell/sourcemap-codec`, `@jridgewell/trace-mapping`,
`lines-and-columns`, and `ts-interface-checker`. Their exact versions are pinned in both the notice
generator and `Scripts/regenerate-sucrase-bundle.sh`. The resulting bundle must retain SHA-256
`4d997e15b72cbc9ccf6e743c30c6eb48bf4533f6709852367b40766be5eba70b`.

`make check` checks both lockfiles, required vendored notices, source-text hashes and the Sucrase bundle
without network access. Adding a SwiftPM dependency requires adding its license source to the generator.
`--verify-upstream` additionally regenerates and compares all text against upstream sources.

To inspect the exact plaintext carried by a release archive:

```sh
python3 Scripts/acknowledgements.py --text-output /tmp/THIRD_PARTY_NOTICES
```
