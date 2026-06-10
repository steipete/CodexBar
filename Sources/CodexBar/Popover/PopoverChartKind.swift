import CodexBarCore
import Foundation

/// popover 二级图表的种类（NSMenu 六类 hosted 子菜单的等价物）。
enum PopoverChartKind: Identifiable, Equatable {
    case usageBreakdown
    case creditsHistory
    case costHistory(UsageProvider)
    case usageHistory(UsageProvider)
    case storageBreakdown(UsageProvider)
    case zaiHourly(UsageProvider)
    /// Zai MCP 用量明细（纯只读列表，等价于 NSMenu makeZaiUsageDetailsSubmenu 内容）。
    case zaiDetails(UsageProvider)

    /// 稳定的 Identifiable id 字符串（无 provider 关联时用种类名，有 provider 时拼接 rawValue）。
    var id: String {
        switch self {
        case .usageBreakdown:
            "usageBreakdown"
        case .creditsHistory:
            "creditsHistory"
        case let .costHistory(provider):
            "costHistory-\(provider.rawValue)"
        case let .usageHistory(provider):
            "usageHistory-\(provider.rawValue)"
        case let .storageBreakdown(provider):
            "storageBreakdown-\(provider.rawValue)"
        case let .zaiHourly(provider):
            "zaiHourly-\(provider.rawValue)"
        case let .zaiDetails(provider):
            "zaiDetails-\(provider.rawValue)"
        }
    }

    /// 入口行标题（对齐 NSMenu 对应行标题，经 L() 本地化）。
    var title: String {
        switch self {
        case .usageBreakdown:
            L("Usage breakdown")
        case .creditsHistory:
            L("Credits history")
        case .costHistory:
            // 与 addCostHistorySubmenu 的 title 完全对齐：依赖 settings.costUsageHistoryDays，
            // 但枚举本身不引用 settings；调用方在构造时已基于条件选择此 kind，
            // title 此处用通用"历史"文案（NSMenu 是动态计算天数后用 L("Usage history (%d days)")，
            // popover 列表 title 暂用不含天数的静态串 L("Usage history (30 days)")，
            // 实际渲染 title 应由调用方使用 costHistoryTitle(settings:) 替换，此为安全默认值）。
            L("Usage history (30 days)")
        case .usageHistory:
            L("Subscription Utilization")
        case .storageBreakdown:
            L("Storage")
        case .zaiHourly:
            L("Hourly Usage")
        case .zaiDetails:
            L("MCP details")
        }
    }

    /// cost history 的动态 title（取决于 settings.costUsageHistoryDays）。
    /// popover 入口行渲染时调用此方法获取带天数的准确标题。
    func costHistoryTitle(historyDays: Int) -> String {
        guard case .costHistory = self else { return self.title }
        if historyDays == 1 {
            return L("Usage history (today)")
        }
        return String(format: L("Usage history (%d days)"), historyDays)
    }

    /// Zai details 入口可用的判定：provider == .zai 且 timeLimit 非空且 usageDetails 非空。
    static func isZaiDetailsAvailable(snapshot: UsageSnapshot?) -> Bool {
        guard let timeLimit = snapshot?.zaiUsage?.timeLimit else { return false }
        return !timeLimit.usageDetails.isEmpty
    }
}
