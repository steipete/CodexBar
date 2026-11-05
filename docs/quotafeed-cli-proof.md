---
summary: "Synthetic shipped-CLI and stable-upgrade evidence for Quota Feed."
read_when:
  - "Validating Quota Feed registration or file ingestion."
---

# Quota Feed CLI proof

Recorded on 2026-11-05 using macOS 26.6.2 arm64, Apple Swift 6.4, and the actual
`CodexBarCLI` executable built with `swift build --product CodexBarCLI`.
No app rendering or full architecture-suite result is claimed.

## Reproduce

Build the CLI, download the latest stable official CLI release into a temporary
location, verify its published SHA256, then run:

```sh
python3 Scripts/test_quota_feed_cli.py /path/to/new/CodexBarCLI /path/to/stable/CodexBarCLI
```

The run below used the latest stable release at validation time,
[v0.83.0](https://github.com/steipete/CodexBar/releases/tag/v0.83.0).
The official `CodexBarCLI-v0.83.0-macos-arm64.tar.gz` checksum was verified against
its companion `.sha256` asset:
`3fb6af9582a0b232dc1708e1d8f13985441dbe2e74903791c902d1fa8bb7c4a9`.
The release was extracted separately; no installed app or user config was replaced.

The script launches both binaries with an allowlisted environment, an explicit
temporary config path, isolated preferences and file discovery, and keychain access
disabled. It uses only synthetic data. All real providers are disabled before any
usage or serve command. HTTP verification is restricted to the temporary loopback
server; no provider network request is needed. Temporary paths are not printed.

## What is asserted

1. The stable binary writes and validates a config with an enabled Codex entry,
   a disabled Claude entry, different source selections, and a defined order.
2. The new binary loads that file without changing its bytes. Its normalized config
   equals the stable binary's entire normalized config after excluding the newly
   registered, disabled-by-default Quota Feed entry.
3. The new binary saves a disable/enable round trip. Both binaries still load it,
   preserving all preexisting normalized fields and provider order. This proves the
   exercised local config upgrade, not every historical app preference or credential
   migration.
4. The actual usage command reads a fresh file (25% used, 75.00 USD remaining),
   rejects a 901-second-old file with exit 1 and no successful usage payload, and
   recovers after atomic replacement (30% used, 70.00 USD remaining). Original
   observation timestamps are retained.
5. The actual serve command returns HTTP 200 `image/svg+xml` with bytes exactly
   matching the app resource. Its HTML includes the Quota Feed icon mapping.

## Captured terminal output

```text
Stable: CodexBar 0.83.0
Upgrade: stable-written config loads unchanged; all existing fields and provider order preserved
Upgrade: new writer round trip preserves settings; stable binary can still read them
current: exit=0 [{"provider": "quotafeed", "rateWindowLabels": {"primary": "Quota"}, "source": "local file", "usage": {"details": [{"rows": [{"label": "Used", "value": "25.00 USD"}, {"label": "Limit", "value": "100.00 USD"}, {"label": "Remaining", "value": "75.00 USD"}], "title": "Quota"}], "primary": {"usedPercent": 25}, "providerCost": {"currencyCode": "USD", "limit": 100, "updatedAt": "2026-11-05T10:07:15Z", "used": 25}, "secondary": null, "tertiary": null, "updatedAt": "2026-11-05T10:07:15Z"}}]
stale: exit=1 [{"error": {"code": 1, "kind": "provider", "message": "Quota feed is stale or its clock is incorrect. Refresh it within 15 minutes and after each reset."}, "provider": "quotafeed", "source": "cli"}]
recovered: exit=0 [{"provider": "quotafeed", "rateWindowLabels": {"primary": "Quota"}, "source": "local file", "usage": {"details": [{"rows": [{"label": "Used", "value": "30.00 USD"}, {"label": "Limit", "value": "100.00 USD"}, {"label": "Remaining", "value": "70.00 USD"}], "title": "Quota"}], "primary": {"usedPercent": 30}, "providerCost": {"currencyCode": "USD", "limit": 100, "updatedAt": "2026-11-05T10:07:15Z", "used": 30}, "secondary": null, "tertiary": null, "updatedAt": "2026-11-05T10:07:15Z"}}]
Icon: HTTP 200 image/svg+xml; exact resource SHA256=938c0aa40aad7ba9c9dfa3b635d76d24e01bfdf6f14027ee66e85608d02f7f5a
Dashboard: Quota Feed icon mapping present
PASS: CLI ingestion, stale recovery, stable upgrade, persisted settings, and standalone icon
```

## Palette and generator checks

The registry fingerprint computation was run with and without Quota Feed:

```text
without Quota Feed: widget=12294021938397504337 burnDown=9386534283149694433
with Quota Feed:    widget=8170844049556855659  burnDown=17791881881353041751
```

The first pair exactly matches the prior audited expectations, confirming existing
provider IDs, ordering, and colors remain unchanged. The second pair is now asserted
in the architecture test. The exact updated test method and its hash helpers also
passed in a core-only harness, alongside the 13 committed QuotaFeedTests and the
baseline-preservation assertion (15 tests total).

`python3 Scripts/generate_serve_provider_icons.py` regenerated the embedded table.
It adds Quota Feed plus two already-present resources previously omitted from the
upstream table (Abliteration and OpenDesign); no existing embedded icon changes.

## Remaining validation

Full app/widget/architecture suites and menu-card screenshots require an Xcode-equipped
machine. This environment has Command Line Tools only (`actool` and SwiftUI macro
plugins required by existing app dependencies are unavailable). The first-party
single-feed scope, schema, and 15-minute freshness policy still require maintainer
approval; this proof does not imply product approval.
