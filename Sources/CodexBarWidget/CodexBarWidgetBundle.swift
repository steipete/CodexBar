import CodexBarCore
import SwiftUI
import WidgetKit

@main
struct CodexBarWidgetBundle: WidgetBundle {
    init() {
        // Without this, every CodexBarCore `self.log.*` call inside the widget extension
        // process (e.g. WidgetSnapshotStore.load()'s read/decode failure logs) silently
        // no-ops — swift-log falls back to a no-op handler until something bootstraps
        // LoggingSystem, and only the main app target was doing that.
        CodexBarLog.bootstrapIfNeeded(.init(
            destination: .oslog(subsystem: "com.steipete.codexbar"),
            level: .verbose,
            json: false))
    }

    var body: some Widget {
        CodexBarSwitcherWidget()
        CodexBarUsageWidget()
        CodexBarHistoryWidget()
        CodexBarCompactWidget()
        CodexBarBurnDownWidget()
        CodexBarCombinedBurnDownWidget()
        CodexBarOverviewWidget()
    }
}

struct CodexBarSwitcherWidget: Widget {
    private let kind = "CodexBarSwitcherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: self.kind,
            provider: CodexBarSwitcherTimelineProvider())
        { entry in
            CodexBarSwitcherWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Switcher")
        .description("Usage widget with a provider switcher.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CodexBarUsageWidget: Widget {
    private let kind = "CodexBarUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: ProviderSelectionIntent.self,
            provider: CodexBarTimelineProvider())
        { entry in
            CodexBarUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Usage")
        .description("Session and weekly usage with credits and costs.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CodexBarHistoryWidget: Widget {
    private let kind = "CodexBarHistoryWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: ProviderSelectionIntent.self,
            provider: CodexBarTimelineProvider())
        { entry in
            CodexBarHistoryWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar History")
        .description("Usage history chart with recent totals.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CodexBarCompactWidget: Widget {
    private let kind = "CodexBarCompactWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: CompactMetricSelectionIntent.self,
            provider: CodexBarCompactTimelineProvider())
        { entry in
            CodexBarCompactWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Metric")
        .description("Compact widget for credits or cost.")
        .supportedFamilies([.systemSmall])
    }
}

struct CodexBarBurnDownWidget: Widget {
    private let kind = "CodexBarBurnDownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: BurnDownSelectionIntent.self,
            provider: BurnDownTimelineProvider())
        { entry in
            BurnDownWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Burn Down")
        .description("Remaining budget compared with an ideal steady burn rate.")
        .supportedFamilies([.systemMedium])
    }
}

struct CodexBarCombinedBurnDownWidget: Widget {
    private let kind = "CodexBarCombinedBurnDownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: BurnProviderSelectionIntent.self,
            provider: CombinedBurnDownTimelineProvider())
        { entry in
            CombinedBurnDownWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Burn Down (Combined)")
        .description("Session and weekly burn-down charts in one tile.")
        .supportedFamilies([.systemMedium])
    }
}

struct CodexBarOverviewWidget: Widget {
    private let kind = "CodexBarOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: self.kind,
            provider: CodexBarOverviewTimelineProvider())
        { entry in
            CodexBarOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Overview")
        .description("Session and weekly usage for all enabled providers in one tile.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
