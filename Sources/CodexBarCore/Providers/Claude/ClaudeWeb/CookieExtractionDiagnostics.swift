enum CookieExtractionEventCategory: String, Sendable {
    case catalogLoadFailed
    case profileRootMissing
    case profileRootEmpty
    case directoryReadFailed
    case noCookieFiles
    case cookieFileUnreadable
    case cookieReadFailed
    case cookieParseFailed
    case cookieQueryFailed
    case duplicateStore

    var summaryLabel: String? {
        switch self {
        case .catalogLoadFailed:
            "catalog load failed"
        case .directoryReadFailed:
            "directory read failed"
        case .noCookieFiles:
            "cookies missing"
        case .cookieFileUnreadable:
            "permission denied"
        case .cookieReadFailed:
            "read failed"
        case .cookieParseFailed:
            "parse failed"
        case .cookieQueryFailed:
            "query failed"
        case .profileRootMissing, .profileRootEmpty, .duplicateStore:
            nil
        }
    }
}

public struct CookieExtractionReport: Sendable {
    enum Level: String, Sendable {
        case info
        case warning
        case error

        var logLabel: String {
            switch self {
            case .info:
                "info"
            case .warning:
                "warn"
            case .error:
                "error"
            }
        }
    }

    struct Event: Sendable {
        let level: Level
        let browser: String?
        let category: CookieExtractionEventCategory?
        let message: String
    }

    private(set) var events: [Event] = []

    mutating func append(_ event: Event) {
        self.events.append(event)
    }

    func compactWarningSummary(maxItems: Int = 3) -> String? {
        self.compactSummary(level: .warning, maxItems: maxItems, label: "Warnings")
    }

    func compactErrorSummary(maxItems: Int = 2) -> String? {
        self.compactSummary(level: .error, maxItems: maxItems, label: "Errors")
    }

    func compactSummary() -> String? {
        let parts = [
            self.compactErrorSummary(),
            self.compactWarningSummary(),
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func compactSummary(level: Level, maxItems: Int, label: String) -> String? {
        let candidates = self.events.filter { event in
            guard event.level == level else { return false }
            return event.category?.summaryLabel != nil
        }
        guard !candidates.isEmpty else { return nil }

        var counts: [SummaryKey: Int] = [:]
        for event in candidates {
            let browser = event.browser ?? "Catalog"
            let category = event.category?.summaryLabel ?? "unknown"
            let key = SummaryKey(browser: browser, category: category)
            counts[key, default: 0] += 1
        }

        let sorted = counts
            .map { SummaryItem(key: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.key.label < rhs.key.label
            }

        let trimmed = sorted.prefix(maxItems)
        let summary = trimmed.map { item in
            let suffix = item.count > 1 ? " (\(item.count))" : ""
            return "\(item.key.label)\(suffix)"
        }
        return "\(label): \(summary.joined(separator: ", "))"
    }

    private struct SummaryKey: Hashable {
        let browser: String
        let category: String

        var label: String {
            "\(self.browser): \(self.category)"
        }
    }

    private struct SummaryItem {
        let key: SummaryKey
        let count: Int
    }
}

final class CookieExtractionReporter {
    private(set) var report = CookieExtractionReport()
    private let logger: ((String) -> Void)?

    init(logger: ((String) -> Void)? = nil) {
        self.logger = logger
    }

    func info(
        _ message: String,
        browser: String? = nil,
        category: CookieExtractionEventCategory? = nil)
    {
        self.record(level: .info, message: message, browser: browser, category: category)
    }

    func warning(
        _ message: String,
        browser: String? = nil,
        category: CookieExtractionEventCategory? = nil)
    {
        self.record(level: .warning, message: message, browser: browser, category: category)
    }

    func error(
        _ message: String,
        browser: String? = nil,
        category: CookieExtractionEventCategory? = nil)
    {
        self.record(level: .error, message: message, browser: browser, category: category)
    }

    func makeClientLogger(browser: String? = nil) -> (String) -> Void {
        { [weak self] message in
            self?.info(message, browser: browser)
        }
    }

    private func record(
        level: CookieExtractionReport.Level,
        message: String,
        browser: String?,
        category: CookieExtractionEventCategory?)
    {
        self.report.append(.init(level: level, browser: browser, category: category, message: message))
        self.logger?(Self.format(level: level, browser: browser, message: message))
    }

    private static func format(
        level: CookieExtractionReport.Level,
        browser: String?,
        message: String) -> String
    {
        if let browser {
            return "[\(level.logLabel)] \(browser): \(message)"
        }
        return "[\(level.logLabel)] \(message)"
    }
}
