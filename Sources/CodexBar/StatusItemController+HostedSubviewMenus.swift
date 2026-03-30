import AppKit

extension StatusItemController {
    func isHostedSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set = [
            "usageBreakdownChart",
            "creditsHistoryChart",
            "costHistoryChart",
            "usageHistoryChart",
            "sessionAnalyticsContent",
            "sessionAnalyticsEmptyState",
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
    }

    func isSessionAnalyticsSubviewMenu(_ menu: NSMenu) -> Bool {
        menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return id.hasPrefix("sessionAnalytics")
        }
    }

    func isOpenAIWebSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set = [
            "usageBreakdownChart",
            "creditsHistoryChart",
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
    }
}
