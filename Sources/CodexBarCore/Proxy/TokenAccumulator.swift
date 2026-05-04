import Foundation

public final class TokenAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AccumulatorKey: AccumulatorValue] = [:]

    public init() {}

    public func record(
        provider: UsageProvider,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        model: String?)
    {
        let key = AccumulatorKey(provider: provider, day: Self.startOfDay(Date()))
        self.lock.lock()
        defer { self.lock.unlock() }

        if var existing = self.entries[key] {
            existing.promptTokens += promptTokens
            existing.completionTokens += completionTokens
            existing.totalTokens += totalTokens
            existing.requestCount += 1
            self.entries[key] = existing
        } else {
            self.entries[key] = AccumulatorValue(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens,
                requestCount: 1)
        }
    }

    public func snapshot(for provider: UsageProvider, day: Date = Date()) -> ProxyTokenEntry? {
        let key = AccumulatorKey(provider: provider, day: Self.startOfDay(day))
        self.lock.lock()
        defer { self.lock.unlock() }

        guard let value = self.entries[key] else { return nil }

        return ProxyTokenEntry(
            provider: provider,
            promptTokens: value.promptTokens,
            completionTokens: value.completionTokens,
            totalTokens: value.totalTokens,
            model: nil,
            timestamp: day)
    }

    public func reset(for provider: UsageProvider, day: Date = Date()) {
        let key = AccumulatorKey(provider: provider, day: Self.startOfDay(day))
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeValue(forKey: key)
    }

    public func allSnapshots() -> [ProxyTokenEntry] {
        self.lock.lock()
        defer { self.lock.unlock() }

        return self.entries.map { key, value in
            ProxyTokenEntry(
                provider: key.provider,
                promptTokens: value.promptTokens,
                completionTokens: value.completionTokens,
                totalTokens: value.totalTokens,
                model: nil,
                timestamp: key.day)
        }
    }

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private struct AccumulatorKey: Hashable {
        let provider: UsageProvider
        let day: Date
    }

    private struct AccumulatorValue {
        var promptTokens: Int
        var completionTokens: Int
        var totalTokens: Int
        var requestCount: Int
    }
}
