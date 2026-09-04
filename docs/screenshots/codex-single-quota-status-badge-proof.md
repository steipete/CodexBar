# Codex single-quota status badge proof

These screenshots use a fixed synthetic input: one full quota, no secondary quota or credits, and a minor
provider-status indicator. They contain only pixels from `IconRenderer` plus the generic labels shown in the
cards. No live provider, account, Keychain, desktop, username, email, or filesystem data is read or displayed.

| Before | After |
| --- | --- |
| ![Before: the status dot floats in the former secondary lane](https://github.com/user-attachments/assets/11622d79-e119-4044-8006-1dea3a48ef7b) | ![After: the status dot attaches to the prominent single-quota meter](https://github.com/user-attachments/assets/acda3704-6095-441b-bbe5-2fa4214ff337) |

The before image was regenerated with the `main` renderer at `c3a25fd85ff0`; the after image uses this
fix integrated with the same base. Both images are byte-identical to the contributor's original proof.
The images are attached to [PR #3354](https://github.com/steipete/CodexBar/pull/3354).

The harness also writes a 120-case pixel matrix covering ten quota layouts, six status indicators, and
the provider-specific and combined icon styles. Exactly twelve single-quota minor/maintenance cases
change; all 108 other renders remain byte-identical, including reserved lanes and severe-status glyphs.

Generate the after proof with:

```sh
CODEXBAR_STATUS_ICON_PROOF_DIR=/tmp/codexbar-status-proof \
  swift test --filter IconRendererScreenshotRenderTests.test_renderSyntheticSingleQuotaStatusBadge
```

The opt-in screenshot test is skipped during normal test runs.
