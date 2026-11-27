import Foundation

package enum Subscription: String, CaseIterable, Identifiable, Sendable {
    case codex
    case kimi
    case antigravity

    package var id: Self {
        self
    }

    package var title: String {
        switch self {
        case .codex: "OpenAI · Codex"
        case .kimi: "Kimi"
        case .antigravity: "Google · Antigravity"
        }
    }
}

package struct QuotaWindow: Equatable, Sendable {
    package let title: String
    package let usedPercent: Decimal
    package let resetsAt: Date?

    init?(title: String, usedPercent: Decimal?, resetsAt: Date?) {
        guard let usedPercent, !usedPercent.isNaN, usedPercent >= 0 else { return nil }
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// A card has one value for both the label and the gauge. Display rounding is confined to the label.
package struct QuotaMenuRow: Equatable {
    package let title: String
    package let percent: Decimal
    package let resetsAt: Date?
    package let showUsed: Bool

    package init(_ window: QuotaWindow, showUsed: Bool) {
        self.title = window.title
        self.resetsAt = window.resetsAt
        self.showUsed = showUsed
        self.percent = showUsed ? window.usedPercent : max(0, 100 - window.usedPercent)
    }

    package var fill: Double {
        min(100, NSDecimalNumber(decimal: self.percent).doubleValue)
    }

    package var label: String {
        let value = if self.percent > 0, self.percent < 0.01 {
            "<0.01"
        } else if self.percent > 99.99, self.percent < 100 {
            ">99.99"
        } else {
            self.percent.formatted(.number.precision(.fractionLength(0...2)))
        }
        return self.showUsed ? "\(value)% 已用" : "\(value)% 剩余"
    }
}

package enum QuotaError: LocalizedError, Equatable {
    case missingCredential
    case unauthorized
    case unavailable
    case http(Int)

    package var errorDescription: String? {
        switch self {
        case .missingCredential: "请在设置中连接此订阅。"
        case .unauthorized: "授权已失效或无权读取额度。请在设置中重新连接。"
        case .unavailable: "服务商未返回可用的额度数据。"
        case let .http(status): "额度查询失败（HTTP \(status)）。"
        }
    }
}
