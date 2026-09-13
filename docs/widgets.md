---
summary: "WidgetKit snapshot pipeline + visibility troubleshooting for CodexBar widgets."
read_when:
  - Modifying WidgetKit extension behavior or snapshot format
  - Debugging widget update timing
  - Widget gallery shows no CodexBar widgets
---

# Widgets

## Snapshot pipeline
- `WidgetSnapshotStore` writes compact JSON snapshots to the app-group container.
- Widgets read the snapshot and render usage/credits/history states.
- Snapshot age labels advance between timeline reloads. Stale token-cost rows track their own saved timestamp once they lag quota data by more than ten minutes. Fetching new usage still depends on app refresh and WidgetKit accepting a timeline.
- The app writes snapshots after the main refresh pipeline and token-usage refreshes; narrow single-provider refresh paths may wait for the next snapshot write.
- Scheduled provider refreshes trigger regular token/cost refreshes; the token/cost TTL determines eligibility when
  that refresh runs. Timer-driven local-history refreshes have a 15-minute minimum (30 minutes in low-power mode).
  Manual disables the recurring refresh timer, not all scan activity: startup refreshes and pending Codex catch-up can
  still scan local history. The floor limits repeated local-history work and extra WidgetKit reload
  requests without changing provider usage/status freshness or the user-selected provider refresh cadence.
- Claude local cost/token history remains eligible for widget snapshots when its account does not expose numeric
  session or weekly quota data.
- Claude Usage widgets can show each known model-scoped weekly quota after the normal Session, Weekly, and Opus rows.
  This includes Fable when Claude exposes it. The rows are opt-in via **Preferences → Providers → Claude → Show
  model-specific weekly usage in widgets**; the setting is off by default and does not affect fetching or other
  CodexBar surfaces. Turning it off also removes scoped rows kept from an earlier snapshot, including while no fresh
  Claude quota data is available.
- If no snapshot is available, widgets fall back to preview/empty data.

Tests must opt into snapshot persistence with an in-memory save override or a test-owned snapshot URL.
Neither opt-in reloads WidgetKit timelines. Production still awaits the file save before requesting a reload;
the save/reload helper accepts an explicit test-mode decision and reload callback so tests can verify that ordering
with temporary files and a fake callback, without changing process-wide test isolation. The per-store reload callback
also lets persistence integration tests count reload attempts without calling WidgetKit.

## Extension
- `Sources/CodexBarWidget` contains timeline + views.
- Usage, Switcher, History, and Metric widgets use WidgetKit's content margins; their views do not add a second outer inset.
- `WidgetExtension/CodexBarWidgetExtension.xcodeproj` builds those sources as the packaged macOS WidgetKit app extension.
- Keep data shape in sync with `WidgetSnapshot` in the main app.

## Widget types
- **CodexBar Switcher** (`CodexBarSwitcherWidget`): static provider switcher widget, small/medium/large.
- **CodexBar Usage** (`CodexBarUsageWidget`): configurable provider usage widget, small/medium/large.
- **CodexBar Account Usage** (`CodexBarAccountUsageWidget`): pins one saved account’s quota windows, small/medium/large.
- **CodexBar History** (`CodexBarHistoryWidget`): configurable usage-history chart, medium/large.
- **CodexBar Metric** (`CodexBarCompactWidget`): compact credits/today-cost/30-day-cost widget, small only.
- **CodexBar Burn Down** (`CodexBarBurnDownWidget`): configurable session or weekly burn-down chart, medium only.
- **CodexBar Burn Down (Combined)** (`CodexBarCombinedBurnDownWidget`): session and weekly burn-down charts, medium only.

Switcher widgets share one remembered provider selection, so switching one updates all Switcher widgets. To keep Claude and Codex visible side by side, add two **CodexBar Usage** widgets and configure each widget's **Provider** separately. Usage widgets read their own configured provider instead of the shared Switcher selection.

## Account selection

Enable **Settings → Menu → Widgets → Keep accounts updated for widgets**, then add a **CodexBar Account Usage**
widget and choose its **Provider** and **Account**. For example, two Account Usage widgets can pin different Claude
accounts while a third widget displays Codex. The existing Usage widget sizes, bars and reset countdowns are reused.
An Account Usage widget without an account shows setup instructions; it never follows the current account implicitly.
Regular **CodexBar Usage** widgets continue following their configured provider as before.

The opt-in keeps saved token accounts and visible Codex accounts refreshing independently of the menu's segmented
or stacked layout, using the existing six-account refresh bound. Claude-swap continues to own its own polling;
its widget choices remain available when only one slot remains. Slot labels and an opaque ownership fingerprint
keep a replacement account from inheriting an old pin without persisting the adapter's personal identity fields.
**Hide personal info** replaces other account labels with ordinals without changing widget account identities.

Codex pins use managed account UUIDs or normalized source/owner identities, not the menu's email-disambiguated
row IDs. Adding or removing a same-email sibling does not change an existing pin. Profile homes remain distinct,
and rotating credentials does not change a pin's identity.

An explicitly selected account never falls back to another account if it is removed, unavailable, or belongs to a
different provider. Transient refresh failures retain the matching account's last-good quota and its original
measurement timestamp; authentication failures and owner changes do not borrow prior account data. Disabling the
setting removes account choices and data from the shared snapshot; provider-only widgets keep working.

Pinned account snapshots currently include quota windows only. Provider-level local cost scans, credits, and history
are not copied into account widgets because their ownership is not necessarily the selected account.
Usage, History, Metric, Switcher, and Burn Down widgets retain their existing provider-only configuration.

### Upgrade and rollback compatibility

The existing widget kinds, `ProviderSelectionIntent`, and provider timeline behavior are unchanged. Account selection
uses a new `CodexBarAccountUsageWidget` kind and a separate `AccountUsageSelectionIntent`; no parameters are added to
persisted configurations of existing widgets. The new intent has no default account. Enabling background account
refresh is a separate opt-in, off by default.

The shared JSON format is additive: older snapshots omit `accounts` and `accountLabel`, and the new reader accepts
them. Older readers ignore those fields in new snapshots. A rollback can rewrite the provider snapshot without
account data; a feature widget reading that rewritten snapshot shows unavailable rather than another account’s quota.
The old app does not provide the new Account Usage widget kind; rollback support applies to the existing provider widgets.
`WidgetSnapshotCompatibilityTests` covers fixed legacy wire data and an older reader/writer, while
`WidgetAccountCompatibilityTests` covers account removal, replacement, identity changes, and refresh failures.

Installed WidgetKit behavior still needs native verification; JSON tests and unchanged intent definitions alone
do not prove the operating system’s upgrade and rollback behavior. In an isolated macOS environment, use baseline and feature bundles with the same bundle
identifiers, signing team, and app group:

1. Install the baseline and add provider-only Usage and History widgets with a non-default provider.
2. Upgrade in place without removing the widgets. Confirm the provider selection, quota, and history remain intact.
3. Opt into account refresh and add two Account Usage widgets with different accounts. Switch the app's selected account,
   refresh, and relaunch; each widget must keep its own pin and measurement.
4. Remove a sibling, then remove or replace a pinned account. Surviving pins must remain stable; removed/replaced
   pins must show unavailable. Opt out and confirm provider-only widgets still work.
5. Roll back the bundle and confirm provider-only widgets still render. Record app/widget versions and screenshots
   separately from synthetic rendering fixtures, with personal information hidden.

## Provider picker support
The configurable provider widgets currently expose:
Codex, Claude, Cursor, Gemini, Alibaba, Antigravity, z.ai, Copilot, MiniMax, Kilo, OpenCode, and OpenCode Go.

Providers without a `ProviderChoice` case can still be present in the app snapshot, but they are not selectable from the widget configuration UI yet.

Burn-down widgets currently support Codex and Claude. Their dedicated configuration intents keep existing Usage and History widget configurations unchanged.

## Visibility troubleshooting (macOS 14+)
When widgets do not appear in the gallery at all, the issue is almost always
registration, signing, or daemon caching (not SwiftUI code).

### 1) Verify the extension bundle exists where macOS expects it
```
APP="/Applications/CodexBar.app"
WAPPEX="$APP/Contents/PlugIns/CodexBarWidget.appex"
WIDGET_ID="com.steipete.codexbar.widget" # debug builds use com.steipete.codexbar.debug.widget

ls -la "$WAPPEX" "$WAPPEX/Contents" "$WAPPEX/Contents/MacOS"
```

### 2) PlugInKit registration (pkd)
```
pluginkit -m -p com.apple.widgetkit-extension -v | grep -i codexbar || true
pluginkit -m -p com.apple.widgetkit-extension -i "$WIDGET_ID" -vv
```
Notes:
- `+` = elected to use, `-` = ignored (PlugInKit elections).
- If missing or ignored, force-add and re-elect:
```
pluginkit -a "$WAPPEX"
pluginkit -e use -p com.apple.widgetkit-extension -i "$WIDGET_ID"
```
- Check for duplicates (old installs or version precedence):
```
pluginkit -m -D -p com.apple.widgetkit-extension -i "$WIDGET_ID" -vv
```
If multiple paths appear, delete older installs and bump `CFBundleVersion`.

### 3) Code signing + Gatekeeper assessment
Widgets are loaded by system daemons. Any signing failure can hide the widget.
```
codesign --verify --deep --strict --verbose=4 /Applications/CodexBar.app
codesign --verify --strict --verbose=4 "$WAPPEX"
codesign --verify --strict --verbose=4 "$WAPPEX/Contents/MacOS/CodexBarWidget"
spctl --assess --type execute --verbose=4 /Applications/CodexBar.app
```

### 4) Restart the right daemons (NotificationCenter alone is not enough)
```
killall -9 pkd || true
sudo killall -9 chronod || true
killall Dock NotificationCenter || true
```

### 5) Watch logs while opening the widget gallery
```
log stream --style compact --predicate '(process == "pkd" OR process == "chronod" OR subsystem CONTAINS "PlugInKit" OR subsystem CONTAINS "WidgetKit")'
```

### 6) Packaging sanity checks
- Widget bundle id should be `com.steipete.codexbar.widget` for release and `com.steipete.codexbar.debug.widget` for debug.
- `NSExtensionPointIdentifier` must be `com.apple.widgetkit-extension`.
- Bundle folder name should match: `CodexBarWidget.appex`.

Optional: re-seed LaunchServices (rarely helps, but low risk):
```
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -seed
```

## Common post-visibility issue: stale data
If the widget appears but always shows preview data:
- App writes snapshot to fallback path while widget reads app-group container.
- Validate that both app and widget resolve the same app-group container.

See also: `docs/ui.md`, `docs/packaging.md`.
