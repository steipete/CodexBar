import SwiftUI
import WidgetKit

@main
struct CodexBariOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexBariOSSwitcherWidget()
        CodexBariOSUsageWidget()
    }
}

struct CodexBariOSSwitcherWidget: Widget {
    private let kind = "CodexBariOSSwitcherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: self.kind, provider: SwitcherTimelineProvider()) { entry in
            SwitcherWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Switcher")
        .description("Switch between Codex and Claude usage snapshots.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct CodexBariOSUsageWidget: Widget {
    private let kind = "CodexBariOSUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: ProviderSelectionIntent.self,
            provider: UsageTimelineProvider())
        { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Usage")
        .description("Codex or Claude quota windows and credits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
