# Shared spend-source publications

Research date: 2026-08-18

## Decision

CodexBar should expose one app-scoped, main-actor publication of immutable spend-source inputs and states. Async producers refresh that publication outside the menu-rendering path. The Overview menu and Usage & Spend dashboard synchronously project the same publication at different densities.

The publication must preserve source identity and truth state:

- Stable source key: provider instance, account/cache identity when applicable, and source kind.
- State: available snapshot, confirmed empty, or unavailable/failed. Absence is not equivalent to confirmed zero.
- Identity metadata: provider-config revision, ownership/scope fingerprint, request generation, and capture time.
- Atomic replacement: consumers see one complete immutable catalog, never a partially mutated dictionary.

Every async producer captures identity before suspension and validates cancellation, generation, provider configuration, and ownership again before publication. Cancellation is only a performance tool; identity validation is the correctness boundary.

Independent dashboard scans also capture the regular token publication revision before suspension. Successful scans (including confirmed empty) acknowledge only that revision; failed attempts are tracked separately to prevent automatic retry loops. A newer regular publication triggers a targeted 365-day scan, with one coalesced follow-up when data arrives during a scan. Regular trigger revisions remain separate from authoritative dashboard data revisions, and short menu snapshots cannot substitute for dashboard history.

This fixes an independently reproduced dashboard freshness gap investigated alongside #3209 and #3176. The screenshot in #3209 is the regular provider-menu cost chart and submenu; its Claude root cause remains unproved. This dashboard fix does not establish a resolution of that report, #3194's Codex quota/persistence issue, or #3207's separate scanner fairness work.

## Why this fits CodexBar

The existing implementation already contains most of the required primitives:

- `TokenSnapshotPublication` carries snapshot, publication revision, provider-config revision, and scope signature.
- `UsageStore` exposes synchronous current-config validation for provider publications.
- Independent dashboard refresh captures identity before loading and revalidates it after suspension.
- `SpendDashboardController` already has immutable request/result values, generation checks, and source-ownership reconciliation.
- Multi-account Codex already uses stable `codex:<account-id>` source identifiers and cache identities.

The architectural gap is that the richer 365-day, multi-account Codex, and OpenCodex result set remains private to a preferences-pane-owned controller. The Overview therefore reads a narrower provider-global cache and cannot achieve source parity.

## UI lifecycle constraint

Menu construction must remain synchronous and cache-only. It must not perform a network request, filesystem scan, or wait for an async refresh. A publication change can invalidate the next menu build, but structural or height-changing mutations should be deferred while AppKit is tracking an open menu.

## Required regression coverage

1. Account A completes after selection changes to account B: A never appears in B's source slot or total.
2. A cancelled non-cooperative loader completes: generation and ownership validation reject it.
3. Two Codex accounts plus OpenCodex remain independently identified and aggregate exactly once.
4. Confirmed-empty, unavailable, failed, and cached-stale states remain distinguishable.
5. Overview and dashboard build from the same published inputs and produce the same math for the same period/calendar.
6. Publication during menu tracking does not structurally rebuild or resize the open menu.

## Primary sources

- [The Swift Programming Language: Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [Apple WWDC25: Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/)
- [Apple AsyncStream documentation](https://developer.apple.com/documentation/Swift/AsyncStream)
- [Swift Evolution SE-0314: AsyncStream and AsyncThrowingStream](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md)
- [Apple Task.cancel documentation](https://developer.apple.com/documentation/Swift/Task/cancel%28%29)
- [Swift Evolution SE-0304: Structured concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)
- [Swift Evolution SE-0306: Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
- [Apple Observation: withObservationTracking](https://developer.apple.com/documentation/observation/withobservationtracking%28_%3Aonchange%3A%29)
- [Apple NSMenuDelegate: menuNeedsUpdate](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate%28_%3A%29)
- [Apple NSMenuDelegate: menuWillOpen](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuwillopen%28_%3A%29)
- [Apple Menu Programming Guide: Views in Menu Items](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/ViewsInMenuItems.html)
