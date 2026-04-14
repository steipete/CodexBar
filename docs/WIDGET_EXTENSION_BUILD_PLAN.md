---
summary: "Plan to replace the manually wrapped SwiftPM widget binary with a script-built Xcode app-extension bundle."
read_when:
  - Fixing the macOS WidgetKit extension packaging path
  - Updating Scripts/package_app.sh for widgets
  - Verifying production widget failures and the scripted app-extension build approach
---

# Widget extension build plan

## Status

The current macOS widget path is broken in both local script-built packages and the latest production release tested during investigation.

### Verified production state
- Release tested: `v0.20`
- Asset tested: `CodexBar-0.20.zip`
- Result: widget is registered but fails during descriptor publication
- Observed production failure signals:
  - widget binary does **not** import `NSExtensionMain`
  - widget still uses legacy app group `group.com.steipete.codexbar`
  - `containermanagerd` rejects the group container request
  - `chronod` reports `getAllDescriptors` failure with `NSCocoaErrorDomain Code=4099`
  - `chronod` reports `No descriptors available`

### Root cause summary
The current packaging flow builds `CodexBarWidget` as a SwiftPM `executableTarget` and then manually wraps that executable in an `.appex` bundle. That bundle can be registered by PlugInKit, but it does not behave like a real WidgetKit app extension at runtime.

A direct swap experiment proved the difference:
- when the packaged app used a real Xcode-built `app-extension` `.appex`, descriptor publication succeeded
- when the packaged app used the existing manually wrapped SwiftPM widget executable, descriptor publication failed

Therefore the fix is to change **how the widget is built**, not just how it is signed or copied.

## Goal

Keep the project script-first and avoid requiring the Xcode GUI, while making the widget build through Apple’s real app-extension pipeline.

Desired final packaging model:
- host app: still built/package-assembled by the existing scripts
- widget: built headlessly with `xcodebuild` as a real macOS `app-extension`
- final app bundle path remains:
  - `CodexBar.app/Contents/PlugIns/CodexBarWidget.appex`
- final signing remains centralized in `Scripts/package_app.sh`

## Non-goals
- Do not require developers to open Xcode manually
- Do not rely on `.swiftpm/xcode/package.xcworkspace`
- Do not keep the manually wrapped SwiftPM widget executable as the shipped path
- Do not migrate the entire host app to an Xcode-first build unless later required for unrelated reasons

## Proven constraints

### What is **not** the remaining blocker
These were isolated and ruled out during debugging:
- stale widget registrations alone
- wrong install location alone
- host app sandbox mismatch alone
- AppIntent-specific logic alone
- widget view/provider business logic alone
- code signing mismatch alone (after correcting TeamIdentifier)
- app-group access alone (for the local alternate-team signed test)

### What **is** the blocker
The widget executable produced by SwiftPM lacks the runtime shape of a real app extension.

Observed binary-level distinction:
- broken SwiftPM-built widget binary:
  - exports `_main`
  - does **not** import `_NSExtensionMain`
- working Xcode-built app-extension binary:
  - exports `_main`
  - imports `_NSExtensionMain`

## Proposed implementation

### 1. Add a script-built widget wrapper project
Add a minimal build-only Xcode wrapper for the widget extension under `Xcode/`.

Recommended files:
- `Xcode/WidgetBuild/project.yml`
- `Xcode/WidgetBuild/CodexBarWidgetExtension/Info.plist`
- `Xcode/WidgetBuild/CodexBarWidgetExtension/CodexBarWidgetExtension.entitlements`
- optional helper sources only if needed

This wrapper should contain an **extension-only** target where possible.

Why extension-only:
- it is enough to produce the correct `.appex`
- it keeps the wrapper minimal
- it avoids unnecessary host-app duplication in the wrapper project

### 2. Build the widget via `xcodebuild`
Add a new script:
- `Scripts/build_widget_extension.sh`

Responsibilities:
- generate the wrapper project if needed
- invoke `xcodebuild` headlessly
- build the widget as a true macOS `app-extension`
- emit or print the path to the built `CodexBarWidget.appex`

Expected output path shape:
- `.build/xcode-widget/DerivedData/Build/Products/<Configuration>/CodexBarWidget.appex`

Recommended build mode:
- `Release` for packaging
- `CODE_SIGNING_ALLOWED=NO` during wrapper build
- final signing handled later by `Scripts/package_app.sh`

### 3. Stop fabricating the widget `.appex` in `package_app.sh`
Remove the current approach that:
- creates the widget bundle directory by hand
- writes a manual widget `Info.plist`
- copies the SwiftPM-built `CodexBarWidget` executable into `Contents/MacOS`

Replace that with:
- call `Scripts/build_widget_extension.sh`
- copy the produced `.appex` wholesale into:
  - `CodexBar.app/Contents/PlugIns/CodexBarWidget.appex`

### 4. Keep final signing in `package_app.sh`
After embedding the Xcode-built widget bundle, continue to sign in this order:
- widget executable
- widget bundle
- host app bundle

Reuse the existing signing variables and entitlements flow:
- `APP_IDENTITY`
- `APP_TEAM_ID`
- app entitlements generated by `package_app.sh`
- widget entitlements generated by `package_app.sh`

This keeps packaging behavior centralized and consistent.

### 5. Move the widget to team-prefixed app groups in the shipped build
The production release currently uses legacy group ids such as:
- `group.com.steipete.codexbar`

The shipped widget must instead use team-prefixed groups, e.g.:
- `<TEAM_ID>.com.steipete.codexbar`

This change is already aligned with the branch work for app-group migration/fallback and must be part of the final shipped widget packaging path.

## Package.swift changes likely needed

The wrapper project should consume shared code cleanly from the package.

Most likely required change:
- expose `CodexBarCore` as a library product in `Package.swift`

Why:
- the wrapper app-extension target needs a clean supported dependency on shared package code
- it should avoid copying or re-listing `CodexBarCore` sources manually

Possible transitional setup:
- keep the existing SwiftPM `CodexBarWidget` target temporarily for tests or local compilation
- stop using its built executable for packaging
- later remove it if it becomes redundant

## Wrapper project requirements

### Target type
- `type: app-extension`
- `platform: macOS`
- product name: `CodexBarWidget`
- bundle id: `com.steipete.codexbar.widget`

### Info.plist requirements
The widget plist should define:
- `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)`
- `CFBundleExecutable = $(EXECUTABLE_NAME)`
- `CFBundlePackageType = XPC!`
- `CFBundleShortVersionString = $(MARKETING_VERSION)`
- `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`
- `NSExtensionPointIdentifier = com.apple.widgetkit-extension`
- `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).CodexBarWidgetBundle`

### Entitlements requirements
The widget entitlements should include:
- `com.apple.security.app-sandbox = true`
- `com.apple.security.application-groups = $(APP_GROUP_ID)`

The final entitlements value must match the team-prefixed group id generated for the build.

## New script design

### `Scripts/build_widget_extension.sh`

Suggested interface:
```bash
./Scripts/build_widget_extension.sh [debug|release]
```

Environment/config inputs:
- `ARCHES`
- `APP_TEAM_ID`
- `APP_GROUP_ID`
- `WIDGET_BUNDLE_ID`
- `MARKETING_VERSION`
- `BUILD_NUMBER`
- optionally `CODEXBAR_WIDGET_DERIVED_DATA`

Suggested responsibilities:
1. validate prerequisites (`xcodebuild`, optionally `xcodegen`)
2. prepare a clean derived data directory under `.build/xcode-widget/`
3. generate the wrapper project if needed
4. build the app-extension target with `xcodebuild`
5. print the produced `.appex` path for callers

Suggested behavior:
- `Release` for packaged builds
- `Debug` only for explicit local diagnostics
- no signing in this script
- fail fast if the resulting `.appex` is missing

### `Scripts/package_app.sh`

New widget flow should be:
1. build host app via SwiftPM as today
2. call `Scripts/build_widget_extension.sh`
3. copy generated `.appex` into `CodexBar.app/Contents/PlugIns/`
4. optionally stamp `CodexBarTeamID` into widget `Info.plist` for runtime parity
5. sign widget executable
6. sign widget bundle
7. sign host app

## Transitional rollout suggestion

Use a temporary switch during migration:
- `CODEXBAR_WIDGET_BUILD_MODE=swiftpm|xcode`

Suggested initial behavior:
- default to `xcode` once validated
- keep `swiftpm` only as a temporary fallback during development

After validation and release confidence:
- remove the old SwiftPM widget packaging path entirely

## Acceptance criteria

### Build correctness
After `Scripts/build_widget_extension.sh release`:
- a `CodexBarWidget.appex` exists
- its executable imports `_NSExtensionMain`
- it contains a valid widget `Info.plist`

### Packaging correctness
After `Scripts/package_app.sh`:
- `CodexBar.app/Contents/PlugIns/CodexBarWidget.appex` exists
- packaged widget TeamIdentifier matches the app TeamIdentifier
- packaged widget entitlements include the team-prefixed app group
- packaged app/group metadata no longer use the legacy `group.com.steipete.codexbar`

### Runtime correctness
After install/register/relaunch:
- `pluginkit` elects the widget at the packaged app path
- `chronod` no longer reports `getAllDescriptors` `Code=4099`
- `chronod` publishes real widget descriptors
- widget snapshot/timeline reload succeeds
- production release path works without relying on stale Xcode debug artifacts

## Validation checklist for implementation

### Binary checks
```bash
nm -m CodexBar.app/Contents/PlugIns/CodexBarWidget.appex/Contents/MacOS/CodexBarWidget | egrep 'NSExtensionMain|main'
```
Expected:
- `_NSExtensionMain` imported

### Signing checks
```bash
codesign -dvvv CodexBar.app
codesign -dvvv CodexBar.app/Contents/PlugIns/CodexBarWidget.appex
codesign -d --entitlements :- CodexBar.app/Contents/PlugIns/CodexBarWidget.appex
```
Expected:
- matching TeamIdentifier
- correct widget entitlements

### Registration/runtime checks
```bash
pluginkit -m -p com.apple.widgetkit-extension -i com.steipete.codexbar.widget -vv
log show --last 5m --style compact --predicate '(process == "chronod" OR process == "containermanagerd") AND (eventMessage CONTAINS[c] "com.steipete.codexbar.widget" OR eventMessage CONTAINS[c] "getAllDescriptors")'
```
Expected:
- packaged widget path elected
- no descriptor invalidation failure

## Risks and cautions

### Ad-hoc signing is still unsafe for real widget validation
Even with the correct extension build pipeline, a real Apple signing identity is still needed for meaningful widget validation on macOS.

### Wrapper project maintenance
If using `project.yml`, the build script depends on `xcodegen` being available.
If that is undesirable, a generated `.xcodeproj` can be checked in instead, but `project.yml` is easier to review and maintain.

### Keep the scope lean
The proven fix target is the widget build/packaging path. Avoid broad host-app build system changes unless a follow-up issue requires them.

## Recommended implementation order

1. Add `CodexBarCore` as a package library product
2. Add the widget wrapper project spec and entitlements/plist files
3. Add `Scripts/build_widget_extension.sh`
4. Update `Scripts/package_app.sh` to embed the Xcode-built `.appex`
5. Keep a temporary `CODEXBAR_WIDGET_BUILD_MODE` fallback if helpful
6. Validate locally using the packaged app path only
7. Remove the old manual widget `.appex` fabrication path once stable

## Evidence summary to preserve
- Official production release `v0.20` widget is currently broken
- Official release widget binary lacks `NSExtensionMain`
- Official release still requests rejected legacy app group `group.com.steipete.codexbar`
- Swapping in a real Xcode-built app-extension `.appex` into the packaged app made descriptor publication succeed
- Therefore the correct fix is a scripted Xcode app-extension build embedded into the existing packaged app flow
