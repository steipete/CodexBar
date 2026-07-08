import SwiftUI
import WidgetKit

@main
struct CodexBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        HomeUsageWidget()
        LockScreenUsageWidget()
        UsageLiveActivityWidget()
    }
}
