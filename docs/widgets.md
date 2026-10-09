---
summary: "WidgetKit snapshot pipeline + visibility troubleshooting for CodexBar widgets."
read_when:
  - Modifying WidgetKit extension behavior or snapshot format
  - Debugging widget update timing
  - Widget gallery shows no CodexBar widgets
---

# Widgets

## Snapshot pipeline
- Quota headlines follow the menu layout: `Weekly 93% left` and `Resets in 1 minute` above the bar. Reset text moves below the headline when the tile is too narrow.
- On macOS 15+, snapshot ages and reset references use live SwiftUI date text with minute precision; WidgetKit advances the text without requesting extra timeline reloads. Reset references use the native calendar wording for distant dates, reach `now` at expiration, and identify elapsed resets afterward. macOS 14 retains native relative-date text for compatibility.
- `WidgetSnapshotStore` writes compact JSON snapshots to the app-group container.
- Widgets read the snapshot and render usage/credits/history states.
- Usage and Switcher tiles emphasize the most constrained general quota, preserve other allowances as detail rows, and show full provider names. Code-review and model-specific allowances do not replace a provider's general quota headline. Providers without quota bars keep credits or local-cost information useful.
- WidgetKit owns the outer margins. All sizes share rendering and quota-selection rules, with overflow labels for omitted rows. Native relative-date text keeps snapshot ages and resets current between timeline reloads. Token-cost rows show their own saved age when more than ten minutes behind quota data. New usage still requires an app refresh and an accepted WidgetKit timeline.
- The app writes snapshots after the main refresh pipeline and token-usage refreshes; narrow single-provider refresh paths may wait for the next snapshot write.
- Claude-swap refreshes and cleared adapter state publish snapshots even when account widgets are off. When Claude-swap owns account presentation, provider widgets follow its active slot and measurement time. Missing quota can retain only that slot owner's saved reading, never ambient or another slot's quota. Local cost remains provider-wide.
- When a failed refresh has no usage for a provider, the writer can retain that provider's last queued entry while it remains enabled and preservation has not been invalidated. Another provider's missing, disabled, or invalidated entry does not discard eligible readings. Measurement timestamps stay unchanged, so widgets show the data's original age. Account invalidation retires only that provider's queued entry until valid replacement usage is published. This fallback is limited to the current app session; it does not restore generic provider entries from disk across account changes or restarts. Claude keeps its existing ownership-checked preservation path.
- Scheduled provider refreshes trigger token/cost refreshes when their TTL permits, with a 15-minute local-history minimum (30 minutes in low-power mode). Manual disables the recurring timer; startup and pending Codex catch-up may still scan. These limits bound history work and WidgetKit reload requests without changing provider usage/status cadence.
- Claude local cost/token history remains eligible for widget snapshots when its account does not expose numeric
  session or weekly quota data.
- **Preferences → Providers → Claude → Show model-specific weekly usage in widgets** adds every known scoped weekly quota (including Fable when available) after Session, Weekly, and Opus. It defaults off, affects no other surface or fetching, and removes even previously saved scoped rows when turned off without fresh data.
- If no snapshot is available, widgets fall back to preview/empty data.

Persistence must finish before requesting a timeline reload. Tests opt in with an in-memory save override or test-owned snapshot URL; neither reloads WidgetKit. Use the helper's explicit test-mode decision and per-store reload callback to verify ordering without changing process-wide isolation or calling WidgetKit.

## Extension
- `Sources/CodexBarWidget` contains timeline + views.
- Usage, Switcher, History, and Metric views must not add a second outer inset to WidgetKit's margins.
- `WidgetExtension/CodexBarWidgetExtension.xcodeproj` builds those sources as the packaged macOS WidgetKit app extension.
- Keep data shape in sync with `WidgetSnapshot` in the main app.

## Widget types
- **CodexBar Switcher** (`CodexBarSwitcherWidget`): static provider switcher widget, small/medium/large.
- **CodexBar Usage** (`CodexBarUsageWidget`): configurable provider usage widget, small/medium/large.
- **CodexBar Account Usage** (`CodexBarAccountUsageWidget`): pins one saved account’s quota windows, small/medium/large.
- **CodexBar History** (`CodexBarHistoryWidget`): configurable usage-history chart, medium/large.
- **CodexBar Metric** (`CodexBarCompactWidget`): credits/today-cost/Cost widget, small only. **Cost** follows the app's [reporting period](cost-reporting-periods.md), including month-to-date and all available history; the period label travels with the snapshot.
- **CodexBar Burn Down** (`CodexBarBurnDownWidget`): configurable quota burn-down chart, medium only.
- **CodexBar Burn Down (Combined)** (`CodexBarCombinedBurnDownWidget`): two quota burn-down charts, medium only.

Switcher widgets share one remembered provider selection, so switching one updates all Switcher widgets. To keep Claude and Codex visible side by side, add two **CodexBar Usage** widgets and configure each widget's **Provider** separately. Usage widgets read their own configured provider instead of the shared Switcher selection.

## Account selection

Enable **Settings → Menu → Widgets → Keep accounts updated for widgets**, add **CodexBar Account Usage**, and choose **Provider** and **Account**. Each widget pins its own account with the usual Usage sizes, bars, and reset countdowns. Without an account it shows setup instructions, never the current account implicitly. Regular **CodexBar Usage** follows its configured provider.

The opt-in refreshes saved token accounts and visible Codex accounts independently of menu layout, bounded to six accounts. Claude-swap owns its polling and remains selectable with one slot. Slot labels and opaque ownership fingerprints prevent replacements from inheriting pins without persisting the adapter's personal identity fields. **Hide personal info** replaces other account labels with ordinals without changing pin identities.

Saved-token pins combine the source UUID with a verified returned owner and any explicit usage scope. Claude OAuth requests the account profile with the same token only when account widgets are enabled. A profile failure keeps the last verified quota at its original age while the credential scope matches; labels never establish ownership. The general usage identity stays unchanged for Cloud Sync and hook throttling. A private app cache stores the verified opaque pin, a one-way credential-scope guard, and quota-only data for offline restarts; it stores no account labels or credentials and is separate from the shared widget JSON. Opt-out, removal, authentication failure, and credential replacement retire the corresponding cached data.

Codex pins combine managed account UUIDs with verified owners or normalized source/owner identities, independent of menu row labels. Same-email sibling changes and credential rotation leave pins stable; profile homes remain distinct.

Selected accounts never fall back to another account or provider. Transient failures retain that account's last-good quota at its original age; authentication failures and owner changes cannot borrow prior data. Disabling account refresh removes choices and data from the shared snapshot while provider-only widgets keep working.

Account snapshots contain quota windows only: provider-level cost, credits, and history may have different owners. Usage, History, Metric, Switcher, and Burn Down remain provider-only.

### Upgrade and rollback compatibility

`CodexBarAccountUsageWidget` uses `AccountUsageSelectionIntent` with no default account. It adds no parameters to existing kinds or `ProviderSelectionIntent` and does not change provider timelines. Background account refresh is a separate opt-in, off by default.

The JSON `accounts` field is optional for new readers and ignored by old readers. A rollback may rewrite snapshots without it; Account Usage then shows unavailable, never another account's quota. Old apps do not provide the Account Usage kind, so rollback support covers provider widgets only.

JSON compatibility does not prove installed WidgetKit upgrade/rollback behavior. Verify in an isolated Mac with old/new signed bundles sharing bundle identifiers, signing team, and app group:

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
Codex, Claude, Gemini, Alibaba, Alibaba Token Plan, Qwen Cloud, Antigravity, Cursor, z.ai / GLM,
Copilot, Devin, MiniMax, Kilo, OpenCode, OpenCode Go, Mistral, Kimi Code, DeepSeek, OpenRouter, and Pi.

DeepSeek shows its credit balance without a quota bar because it reports no quota denominator.
OpenRouter shows its remaining credits alongside a configured API-key limit, or as the headline when
the key is uncapped. The Metric widget's **Credits left** choice shows the same balance for both providers.

Providers without a `ProviderChoice` case can still be present in the app snapshot, but they are not selectable from the widget configuration UI yet.

Burn-down provider choices are filtered from the enabled providers in the latest saved snapshot. A quota
qualifies when it has a finite usage percentage, a positive `windowMinutes`, a reset date, and is not a
synthetic placeholder. The compile-time AppIntent catalog covers all built-in providers; providers that
only report balances, unknown durations, or unknown resets do not appear. Refresh CodexBar before
configuring a newly enabled provider. Custom plugin instance IDs are not part of the AppEnum catalog.

For **Burn Down**, select **Provider**, then **Usage window**. The choices use the snapshot's quota names:
Devin offers **Daily** and **Weekly**; Cursor offers **Total**, **Cursor**, and **Third Party** when those
billing-cycle quotas are present. Each chart uses that quota's actual duration and reset, including
Cursor's billing cycle. The choice stays pinned to its quota slot: missing data shows the empty state,
never another quota. Provider titles in the snapshot take precedence over descriptor defaults.

**Burn Down (Combined)** shows the first two quota lanes with their own names and durations, such as
Devin's **Daily & Weekly** or Cursor's **Total & Cursor**. A missing lane shows **No data** under its own
name. The single widget also offers the third quota when available. Combined requires a compatible first or
second quota; a provider with only a compatible third quota appears in the single widget picker.

Saved Codex/Claude intents retain their types, raw values, defaults, and exact **Session (5-hour)** / **Weekly (7-day)** meanings. Combined keeps those lanes and weekly-cap behavior; quota-slot choices and Combined use actual durations when different. Additive cases require no widget reconfiguration and preserve snapshot/empty-data handling and the 5–30-minute timeline schedule. This does not prevent Homebrew removing widget placements (#3627).

Include a non-default Claude/Weekly widget in native upgrade verification, then check Devin/Cursor choices in the editor. Synthetic renders prove layout only, not installed WidgetKit behavior.

## Visibility troubleshooting (macOS 14+)
When widgets do not appear in the gallery at all, the issue is almost always
registration, signing, or daemon caching (not SwiftUI code).

### Widgets removed during Homebrew upgrades

Homebrew replaces the app bundle during a cask upgrade. Even when it preserves the outer
`CodexBar.app` directory, its removal of the old contents temporarily removes the embedded
widget extension. macOS can treat that as an uninstall and remove placed widgets (#3627).
If CodexBar is still in the gallery but desktop or Notification Center widgets disappeared,
re-registering the extension or reloading timelines does not restore their saved placements
and configuration. WidgetCenter exposes configuration queries and reload requests, not an
API for restoring removed widget placements. Add and configure those widgets again.

`brew upgrade --formula` upgrades formulae only and can defer cask replacement until you are
ready to reconfigure widgets; it does not update CodexBar. Neither `--no-quit` nor `--no-binaries`
prevents replacement of the app's embedded extension. For an alternative update mechanism,
use a standalone GitHub release installation with Sparkle; Homebrew-managed installations
disable Sparkle. Widget placement preservation with that alternative still needs native
upgrade testing and is not guaranteed here.

### Timelines remain stale despite successful extension logs

`reloadAllTimelines()` requests an update; it does not confirm that `chronod` accepted the
rendered timeline. An extension-side success log can therefore coexist with
`CHSErrorDomain` 1050 (`timelineReloadFailed`), as reported in #3339. Current providers emit
one timeline entry and request the next update 5–30 minutes later (30 minutes for Metric).
Expired reset dates do not schedule a reload in the past. The snapshot reader does not
impose a byte limit, so a problematic payload still needs to be examined before ruling
out resource pressure.

For this specific failure, collect app/extension versions, snapshot byte size, and matching
extension and `chronod` logs. The reporter recovered by quitting only the `CodexBarWidget`
extension process and allowing macOS to relaunch it. This is a manual diagnostic workaround,
not an automatic recovery policy; restarting the main app may leave that process alive.

After an update, distinguish the installed extension from the executable already mapped by
its running process. In #2838 the reporter found an old extension mapped from a deleted
Sparkle staging directory while the installed app and extension had matching new versions.
`chronod` reported `bundleStubNotSupported` and "Bundle version did not match" before error
1050. The process command shown by `ps` and the installed `Info.plist` do not establish the
version of the running executable. Compare its mapped executable using `lsof -p <pid>` with
the installed extension, and redact paths before sharing logs. Reload requests and a fresh
snapshot alone do not replace a stale extension process. This failure is separate from
Homebrew deleting widget placements and from a snapshot containing no provider entries.

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
