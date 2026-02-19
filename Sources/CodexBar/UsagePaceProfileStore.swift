import CodexBarCore
import Foundation

@MainActor
final class UsagePaceProfileStore {
    private static let weeklyWindowMinutes = 7 * 24 * 60
    private static let weeklyWindowToleranceMinutes = 24 * 60

    private struct PersistedState: Codable {
        let providers: [String: ProviderState]
    }

    private struct ProviderState: Codable {
        var hourlyRates: [Double]
        var hourlySamples: [Int]
        var sampleCount: Int
        var firstObservation: Date?
        var lastObservation: Date?
        var lastUsedPercent: Double?
        var lastSeenAt: Date?
        var lastResetAt: Date?
        var lastWindowMinutes: Int?

        static var empty: ProviderState {
            ProviderState(
                hourlyRates: Array(repeating: 0, count: UsagePaceProfile.binsPerWeek),
                hourlySamples: Array(repeating: 0, count: UsagePaceProfile.binsPerWeek),
                sampleCount: 0,
                firstObservation: nil,
                lastObservation: nil,
                lastUsedPercent: nil,
                lastSeenAt: nil,
                lastResetAt: nil,
                lastWindowMinutes: nil)
        }

        mutating func normalize() {
            self.hourlyRates = Self.normalizeRates(self.hourlyRates)
            self.hourlySamples = Self.normalizeSamples(self.hourlySamples)
            self.sampleCount = max(0, self.sampleCount)
        }

        mutating func record(window: RateWindow, now: Date) -> Bool {
            self.normalize()

            let used = min(100, max(0, window.usedPercent))
            guard used.isFinite else {
                self.updateLastObservation(window: window, now: now, used: nil)
                return false
            }

            guard let previousUsed = self.lastUsedPercent,
                  let previousSeen = self.lastSeenAt
            else {
                self.updateLastObservation(window: window, now: now, used: used)
                return false
            }

            let elapsed = now.timeIntervalSince(previousSeen)
            guard elapsed >= 60, elapsed <= (6 * 60 * 60) else {
                self.updateLastObservation(window: window, now: now, used: used)
                return false
            }

            let resetAdvanced = Self.didAdvanceReset(previous: self.lastResetAt, current: window.resetsAt)
            let delta = used - previousUsed
            if resetAdvanced || delta < -0.5 {
                self.updateLastObservation(window: window, now: now, used: used)
                return false
            }

            guard delta > 0 else {
                self.updateLastObservation(window: window, now: now, used: used)
                return false
            }

            let clampedDelta = min(delta, 40)
            let rate = clampedDelta / elapsed
            if rate.isFinite == false || rate <= 0 {
                self.updateLastObservation(window: window, now: now, used: used)
                return false
            }

            let midpoint = previousSeen.addingTimeInterval(elapsed / 2)
            let bin = UsagePaceProfile.binIndex(for: midpoint)
            guard self.hourlyRates.indices.contains(bin), self.hourlySamples.indices.contains(bin) else {
                self.updateLastObservation(window: window, now: now, used: used)
                return false
            }

            let priorSamples = max(0, self.hourlySamples[bin])
            let priorRate = max(0, self.hourlyRates[bin])
            let nextRate = if priorSamples == 0 {
                rate
            } else {
                ((priorRate * Double(priorSamples)) + rate) / Double(priorSamples + 1)
            }

            self.hourlyRates[bin] = nextRate
            self.hourlySamples[bin] = priorSamples + 1
            self.sampleCount += 1
            self.firstObservation = self.firstObservation ?? midpoint
            self.lastObservation = midpoint
            self.updateLastObservation(window: window, now: now, used: used)
            return true
        }

        func makeProfile() -> UsagePaceProfile {
            let activeBins = self.hourlySamples.reduce(into: 0) { count, samples in
                if samples > 0 {
                    count += 1
                }
            }
            let spanHours = if let first = self.firstObservation, let last = self.lastObservation {
                Int(max(0, last.timeIntervalSince(first)) / 3600)
            } else {
                0
            }
            return UsagePaceProfile(
                hourlyIntensity: self.hourlyRates,
                sampleCount: self.sampleCount,
                activeBinCount: activeBins,
                spanHours: spanHours)
        }

        private mutating func updateLastObservation(window: RateWindow, now: Date, used: Double?) {
            self.lastUsedPercent = used
            self.lastSeenAt = now
            self.lastResetAt = window.resetsAt
            self.lastWindowMinutes = window.windowMinutes
        }

        private static func didAdvanceReset(previous: Date?, current: Date?) -> Bool {
            guard let previous, let current else { return false }
            return current.timeIntervalSince(previous) > (6 * 60 * 60)
        }

        private static func normalizeRates(_ input: [Double]) -> [Double] {
            let cleaned = input.map { value in
                if value.isFinite {
                    return max(0, value)
                }
                return 0
            }

            if cleaned.count == UsagePaceProfile.binsPerWeek {
                return cleaned
            }
            if cleaned.count > UsagePaceProfile.binsPerWeek {
                return Array(cleaned.prefix(UsagePaceProfile.binsPerWeek))
            }
            return cleaned + Array(repeating: 0, count: UsagePaceProfile.binsPerWeek - cleaned.count)
        }

        private static func normalizeSamples(_ input: [Int]) -> [Int] {
            let cleaned = input.map { max(0, $0) }
            if cleaned.count == UsagePaceProfile.binsPerWeek {
                return cleaned
            }
            if cleaned.count > UsagePaceProfile.binsPerWeek {
                return Array(cleaned.prefix(UsagePaceProfile.binsPerWeek))
            }
            return cleaned + Array(repeating: 0, count: UsagePaceProfile.binsPerWeek - cleaned.count)
        }
    }

    private var providers: [UsageProvider: ProviderState]

    private init(providers: [UsageProvider: ProviderState]) {
        self.providers = providers
    }

    static func load() -> UsagePaceProfileStore {
        guard let url = self.storageURL,
              let data = try? Data(contentsOf: url)
        else {
            return UsagePaceProfileStore(providers: [:])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let decoded = try? decoder.decode(PersistedState.self, from: data) else {
            return UsagePaceProfileStore(providers: [:])
        }

        let mapped = decoded.providers.reduce(into: [UsageProvider: ProviderState]()) { partial, element in
            guard let provider = UsageProvider(rawValue: element.key) else { return }
            var state = element.value
            state.normalize()
            partial[provider] = state
        }
        return UsagePaceProfileStore(providers: mapped)
    }

    func profile(for provider: UsageProvider) -> UsagePaceProfile {
        guard let state = self.providers[provider] else { return .empty }
        return state.makeProfile()
    }

    func record(provider: UsageProvider, snapshot: UsageSnapshot, now: Date = .init()) {
        guard let weekly = self.weeklyWindow(in: snapshot) else { return }
        var state = self.providers[provider] ?? .empty
        let changed = state.record(window: weekly, now: now)
        self.providers[provider] = state
        if changed {
            self.save()
        }
    }

    private func weeklyWindow(in snapshot: UsageSnapshot) -> RateWindow? {
        let candidates = [snapshot.secondary, snapshot.primary, snapshot.tertiary]
        for candidate in candidates {
            guard let candidate else { continue }
            guard Self.isWeeklyWindow(candidate) else { continue }
            return candidate
        }
        return nil
    }

    private static func isWeeklyWindow(_ window: RateWindow) -> Bool {
        let minutes = window.windowMinutes ?? Self.weeklyWindowMinutes
        let delta = abs(minutes - Self.weeklyWindowMinutes)
        return delta <= Self.weeklyWindowToleranceMinutes
    }

    private func save() {
        guard let url = Self.storageURL else { return }
        let serialized = self.providers.reduce(into: [String: ProviderState]()) { partial, element in
            partial[element.key.rawValue] = element.value
        }

        let payload = PersistedState(providers: serialized)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static var storageURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let dir = root.appendingPathComponent("com.steipete.codexbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        return dir.appendingPathComponent("pace-profiles-v1.json", isDirectory: false)
    }
}
