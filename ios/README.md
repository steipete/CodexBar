# CodexBar for iPhone

A native, Liquid Glass iOS companion that mirrors the usage your Mac already aggregates —
provider usage windows, credits, and token cost — on the Home Screen, Lock Screen, and
(optionally) as a Live Activity.

**Design goal:** *read-only mirror.* The Mac aggregates every provider (as it does today) and
ships the exact same `WidgetSnapshot` to the phone. No provider credentials ever live on the
phone.

## Architecture

```
 macOS CodexBar                          iPhone
 ┌─────────────────────┐                 ┌──────────────────────────────┐
 │ UsageStore          │   LAN (Bonjour) │ SnapshotSyncCoordinator      │
 │  persistWidgetSnap ─┼──── _codexbar- ─┼─► LANSubscriber              │
 │  MobileSyncPublisher│    sync._tcp    │   CloudKitSnapshotClient     │
 │   ├─ NWListener     │                 │        │                     │
 │   └─ CKContainer  ──┼──── iCloud ─────┼─► App Group cache ──► Widgets│
 │      (private DB)   │   (private DB)  │                       Live   │
 └─────────────────────┘                 │                     Activity│
                                          └──────────────────────────────┘
```

- **LAN (fast path):** the Mac advertises `_codexbar-sync._tcp` over Bonjour and streams a
  length-prefixed JSON `SyncEnvelope`. Instant, offline, zero-config — used while the app is
  foreground on the same Wi-Fi.
- **iCloud (backbone):** the Mac writes the snapshot to the user's **private CloudKit database**.
  This is the only transport that keeps widgets / Lock Screen / Live Activities fresh while the
  phone is backgrounded and away from the Mac. 100% user-managed — their iCloud, **no server, no
  Cloudflare Worker**.
- **Merge rule:** newest `generatedAt` wins, regardless of transport.

Live Activities are **off by default** (opt-in in Settings). Without a push server we cannot update
a Live Activity remotely via APNs, so activities refresh locally when the app ingests a new snapshot
(foreground or a CloudKit background wake).

## Layout

| Path | Contents |
|------|----------|
| `ios/Shared/Model` | Wire-contract mirror of `CodexBarCore.WidgetSnapshot` (Foundation-only) |
| `ios/Shared/Transport` | `SyncEnvelope`, `LANSubscriber`, `CloudKitSnapshotClient`, `SnapshotSyncCoordinator` |
| `ios/Shared/LiveActivity` | `UsageActivityAttributes` (shared by app + widget) |
| `ios/Shared/UI` | Liquid Glass design system + shared SwiftUI components |
| `ios/CodexBarMobile` | The app (SwiftUI), Live Activity controller, app icon + provider assets |
| `ios/CodexBarMobileWidget` | Home + Lock Screen widgets and the Live Activity widget |

The macOS publisher lives in `Sources/CodexBar/MobileSync/`. It is **opt-in** and a no-op unless
`UserDefaults.standard.bool(forKey: "mobileSyncEnabled")` is true, so existing users are unaffected.

## Building

```sh
cd ios
xcodegen generate
xcodebuild -project CodexBarMobile.xcodeproj -scheme CodexBarMobile \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

DEBUG builds seed sample data on first launch so the UI renders without a live Mac. Two launch
arguments drive deterministic screenshots: `-screen settings`, `-screen detail`.

## Capabilities required for a signed device build

The repo's tooling keeps the checked-in `.entitlements` empty for unsigned simulator builds. To
run on a device / ship, add these (App target unless noted):

- **App Group** `group.com.steipete.codexbar.ios` — app + widget + Live Activity (both targets)
- **iCloud → CloudKit**, container `iCloud.com.steipete.codexbar` (`com.apple.developer.icloud-services = [CloudKit]`)
- **Push Notifications** (`aps-environment`) — for CloudKit silent pushes
- **Background Modes → Remote notifications**

On the **macOS** side, publishing needs `com.apple.security.network.server` (Bonjour LAN listener)
and the same iCloud/CloudKit container entitlement.

Both transports self-gate at runtime: CloudKit is skipped unless an iCloud identity is present
(`CKContainer(identifier:)` traps without the entitlement), and LAN advertising simply fails
closed without the server entitlement — so an unsigned build runs and mirrors over LAN in the
simulator without crashing.
