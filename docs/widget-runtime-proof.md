# Widget live-date validation

## Installed contributor evidence

The installed medium Switcher capture belongs to contributor revision
[`e6a9be2dfa3d`](https://github.com/brzvsk/CodexBar/commit/e6a9be2dfa3dc7fa1974e87c5f4b2ce6bab39543).
It uses synthetic data (93% weekly remaining), not a provider account. The
[original report](https://github.com/brzvsk/CodexBar/blob/e6a9be2dfa3dc7fa1974e87c5f4b2ce6bab39543/docs/widget-runtime-proof.md)
retains the screenshots, source hashes, accessibility captures, timeline log, and reproduction fixture.

Pixels and accessibility agree: the age advances from five to nine minutes, and the reset changes
from “in 1 minute” through “now” to “3 minutes ago.” The captures precede the earliest requested
reload, with no provider invocation between them. All five renderer hashes match that revision.
This establishes installed behavior for that medium Switcher, not the final localization changes,
small/large installed widgets, account fetching, or macOS 14.

The original report also preserves failed experiments: an extension-defined formatter could not
be decoded by Notification Center, and a Foundation components range advanced accessibility text
while its visible pixels stayed frozen. Keep the native system DateOffset/DateReference formatters;
in-process renders alone cannot establish WidgetKit archive decoding or clock advancement.

## Maintainer integration checks

`WidgetDateTextTests` exercises minute-boundary advancement and expired reset references using fixed
dates. `WidgetHeadlineLocalizationTests` checks translated headline pixels and the localization bundle
used by reset text. `WidgetHeadlineRenderTests` renders the production Usage tile in small, medium,
and large sizes with English, German, and Arabic, using only synthetic snapshots. Set
`CODEXBAR_WIDGET_HEADLINE_PROOF_DIR` to an existing directory to save the PNGs for visual inspection.
These are headless layout captures, not installed WidgetKit runtime proof.

The macOS 14 branch retains native relative-date text; the package and extension deployment target
remain 14.0. Native macOS 14 runtime verification requires a separate compatible guest.
Timeline scheduling, reload requests, snapshot schemas, and account selection are unchanged.
