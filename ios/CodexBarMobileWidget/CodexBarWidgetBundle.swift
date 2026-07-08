import SwiftUI
import WidgetKit

@main
struct CodexBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        HomeUsageWidget()
        HistoryWidget()
        CompactWidget()
        BurnDownWidget()
        CombinedBurnDownWidget()
        SwitcherWidget()
        LockScreenUsageWidget()
        UsageLiveActivityWidget()
    }
}
