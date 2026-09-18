# Overview sharing proof

Synthetic data only. Captured on disposable macOS CI runners on 2026-09-16.

[Run 35117321221](https://github.com/Chipagosfinest/CodexBar/actions/runs/35117321221), source `4570f66a0c21ebf1dbff48ecd48a643993f83f74`, passed 17 export tests and the native menu interaction test in both English and German. The workflow required all nine PNG artifacts. Images in this directory are from that successful run.

The native test dispatched the real overview action, opened its visible preview, and verified that a selected $2 payload excluded a hidden $900 source. Return activated the default Copy Image control. Assertions verified a new clipboard write containing PNG and TIFF, with PNG dimensions 1200 × 630. Clipboard writes occurred only in the disposable runner.

## Actual window captures

Visual inspection confirms the complete controls and successful copy feedback, with no clipped English or German labels:

- [English before copy](overview-share-window.png)
- [English after copy: Image copied](overview-share-window-copied.png)
- [German before copy: Bild kopieren](overview-share-window-de.png)
- [German after copy: Bild kopiert](overview-share-window-copied-de.png)

![Synthetic exported usage image](share-stats.png)

The preview hosting-view captures omit the native toolbar; use the compositor captures above for control and feedback evidence. The pre-existing next-day footer date visible here is tracked independently on `fix/share-period-date`.

## Verification boundaries

These are native test-host results, not installed desktop-widget proof. VoiceOver behavior remains unverified. Recursive accessibility traversal is a separate explicit opt-in (`CODEXBAR_OVERVIEW_ACCESSIBILITY_PROOF=1`); ordinary proof logs state that accessibility was not verified.

Earlier [run 35083394374](https://github.com/Chipagosfinest/CodexBar/actions/runs/35083394374) failed overall because its in-process accessibility traversal returned no elements in either language, although action, clipboard, and screenshot checks passed. Separating that unsupported traversal does not turn its failed result into a pass or certify accessibility.

The layout correction follows [Apple NSWindow.layoutIfNeeded](https://developer.apple.com/documentation/appkit/nswindow/layoutifneeded()), accessed 2026-09-16. The optional traversal follows [Apple accessibilityChildren](https://developer.apple.com/documentation/AppKit/NSAccessibility-c.protocol/accessibilityChildren) and the repository's existing SwiftUI-node fallback. No manual hosting-view size was assigned.
