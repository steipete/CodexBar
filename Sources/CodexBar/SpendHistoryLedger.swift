import CodexBarCore
import Foundation

/// Durable, account-scoped daily cost history for the spend dashboard.
///
/// Provider snapshots are rolling windows. This ledger keeps only days for which a provider
/// established coverage, so an "All Time" view can distinguish tracked history from a guess.
actor SpendHistoryLedger {
    typealias FileWriter = @Sendable (Data, URL) throws -> Void
    typealias PermissionEnforcer = @Sendable (URL) throws -> Bool

    struct Snapshot: Sendable {
        let input: SpendDashboardModel.ProviderInput
        let coverageStart: Date
        let coverageEnd: Date
        let coveredDayCount: Int
        let hasContinuousCoverage: Bool
    }

    private struct Document: Codable {
        let version: Int
        var sources: [Source]
    }

    private struct Source: Codable {
        let sourceID: String
        let provider: UsageProvider
        var displayName: String
        var modelProviderName: String
        let ownershipFingerprint: String
        let currencyCode: String
        var days: [Day]
    }

    private struct Day: Codable, Equatable {
        let date: String
        let inputTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        let requestCount: Int?
        let cost: Double
        let modelsUsed: [String]?
        let modelBreakdowns: [Model]
    }

    private struct Model: Codable, Equatable {
        let modelName: String
        let cost: Double?
        let totalTokens: Int?
        let requestCount: Int?
        let standardCost: Double?
        let priorityCost: Double?
        let standardTokens: Int?
        let priorityTokens: Int?
    }

    private static let schemaVersion = 1
    private let fileURL: URL
    private let fileManager: FileManager
    private let fileWriter: FileWriter
    private let permissionEnforcer: PermissionEnforcer
    private var document: Document?

    init(
        fileURL: URL = SpendHistoryLedger.defaultFileURL(),
        fileManager: FileManager = .default,
        fileWriter: @escaping FileWriter = { data, url in
            try data.write(to: url, options: [.atomic])
        },
        permissionEnforcer: @escaping PermissionEnforcer = { url in
            try SpendHistoryLedger.enforceOwnerOnlyPermissions(at: url)
        })
    {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.fileWriter = fileWriter
        self.permissionEnforcer = permissionEnforcer
    }

    /// Records complete provider windows and returns every matching tracked source.
    /// Invalid or partial windows are ignored without deleting previously proven history.
    func record(
        inputs: [SpendDashboardModel.ProviderInput],
        ownership: [String: String]) -> [Snapshot]
    {
        let durableDocument = self.load()
        var candidateDocument = durableDocument
        var changed = false

        for input in inputs {
            guard let fingerprint = ownership[input.id],
                  let capturedDays = Self.completeDays(from: input)
            else { continue }
            let currencyCode = input.snapshot.currencyCode.uppercased()
            let matchingIndex = candidateDocument.sources.firstIndex {
                $0.sourceID == input.id &&
                    $0.provider == input.provider &&
                    $0.ownershipFingerprint == fingerprint &&
                    $0.currencyCode == currencyCode
            }
            if let matchingIndex {
                var source = candidateDocument.sources[matchingIndex]
                let priorDays = Dictionary(uniqueKeysWithValues: source.days.map { ($0.date, $0) })
                var mergedDays = priorDays
                for day in capturedDays {
                    mergedDays[day.date] = day
                }
                source.displayName = input.displayName
                source.modelProviderName = input.modelProviderName
                source.days = mergedDays.values.sorted { $0.date < $1.date }
                changed = changed || source.days != candidateDocument.sources[matchingIndex].days ||
                    source.displayName != candidateDocument.sources[matchingIndex].displayName ||
                    source.modelProviderName != candidateDocument.sources[matchingIndex].modelProviderName
                candidateDocument.sources[matchingIndex] = source
            } else {
                candidateDocument.sources.append(Source(
                    sourceID: input.id,
                    provider: input.provider,
                    displayName: input.displayName,
                    modelProviderName: input.modelProviderName,
                    ownershipFingerprint: fingerprint,
                    currencyCode: currencyCode,
                    days: capturedDays))
                changed = true
            }
        }

        if changed {
            candidateDocument.sources.sort {
                ($0.sourceID, $0.ownershipFingerprint, $0.currencyCode) <
                    ($1.sourceID, $1.ownershipFingerprint, $1.currencyCode)
            }
            guard self.persist(candidateDocument) else {
                return Self.snapshots(document: durableDocument, inputs: inputs, ownership: ownership)
            }
            self.document = candidateDocument
        }
        return Self.snapshots(document: candidateDocument, inputs: inputs, ownership: ownership)
    }

    func snapshots(
        for inputs: [SpendDashboardModel.ProviderInput],
        ownership: [String: String]) -> [Snapshot]
    {
        Self.snapshots(
            document: self.load(),
            inputs: inputs,
            ownership: ownership)
    }

    private func load() -> Document {
        if let document = self.document { return document }
        let permissionsAreSafe = Self.hasOwnerOnlyPermissions(at: self.fileURL) ||
            ((try? self.permissionEnforcer(self.fileURL)) == true &&
                Self.hasOwnerOnlyPermissions(at: self.fileURL))
        let decoded = permissionsAreSafe
            ? try? JSONDecoder().decode(Document.self, from: Data(contentsOf: self.fileURL))
            : nil
        let document = decoded?.version == Self.schemaVersion
            ? decoded ?? Document(version: Self.schemaVersion, sources: [])
            : Document(version: Self.schemaVersion, sources: [])
        self.document = document
        return document
    }

    private func persist(_ document: Document) -> Bool {
        let parentURL = self.fileURL.deletingLastPathComponent()
        let candidateURL = parentURL
            .appendingPathComponent(".\(self.fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let backupName = ".\(self.fileURL.lastPathComponent).\(UUID().uuidString).backup"
        let backupURL = parentURL.appendingPathComponent(backupName)
        defer { try? self.fileManager.removeItem(at: candidateURL) }
        defer { try? self.fileManager.removeItem(at: backupURL) }
        do {
            try self.fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try self.fileWriter(encoder.encode(document), candidateURL)
            guard try self.permissionEnforcer(candidateURL) else { return false }
            if self.fileManager.fileExists(atPath: self.fileURL.path) {
                _ = try self.fileManager.replaceItemAt(
                    self.fileURL,
                    withItemAt: candidateURL,
                    backupItemName: backupName)
            } else {
                try self.fileManager.moveItem(at: candidateURL, to: self.fileURL)
            }
            guard Self.hasOwnerOnlyPermissions(at: self.fileURL) else {
                try? self.fileManager.removeItem(at: self.fileURL)
                if self.fileManager.fileExists(atPath: backupURL.path) {
                    try? self.fileManager.moveItem(at: backupURL, to: self.fileURL)
                }
                return false
            }
            return true
        } catch {
            // Best-effort local history must never make provider refresh fail.
            return false
        }
    }

    private static func completeDays(from input: SpendDashboardModel.ProviderInput) -> [Day]? {
        let snapshot = input.snapshot
        guard snapshot.historyCoverageIsEstablished,
              snapshot.historyDays > 0,
              Self.validAggregate(snapshot.last30DaysCostUSD)
        else { return nil }
        let calendar = Self.calendar(for: input.provider)
        let end = calendar.startOfDay(for: snapshot.updatedAt)
        guard let start = calendar.date(byAdding: .day, value: -(snapshot.historyDays - 1), to: end) else {
            return nil
        }
        var entriesByDate: [String: CostUsageDailyReport.Entry] = [:]
        for entry in snapshot.daily {
            guard let date = Self.day(entry.date, calendar: calendar) else {
                guard SpendDashboardModel.hasProvenZeroCost(entry) else { return nil }
                continue
            }
            guard date >= start, date <= end else {
                guard SpendDashboardModel.hasProvenZeroCost(entry) else { return nil }
                continue
            }
            guard Self.validCost(entry.costUSD) != nil else { return nil }
            let key = Self.dayKey(date, calendar: calendar)
            guard entriesByDate[key] == nil else { return nil }
            entriesByDate[key] = entry
        }
        let observedTotal = entriesByDate.values.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
        guard observedTotal.isFinite,
              let aggregate = snapshot.last30DaysCostUSD,
              SpendDashboardModel.costsMatch(observedTotal, aggregate)
        else { return nil }

        return (0..<snapshot.historyDays).compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = Self.dayKey(date, calendar: calendar)
            return Self.dayRecord(date: key, entry: entriesByDate[key])
        }
    }

    private static func snapshots(
        document: Document,
        inputs: [SpendDashboardModel.ProviderInput],
        ownership: [String: String]) -> [Snapshot]
    {
        let currentInputs = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        return document.sources.compactMap { source in
            guard ownership[source.sourceID] == source.ownershipFingerprint,
                  currentInputs[source.sourceID].map({
                      $0.provider == source.provider &&
                          $0.snapshot.currencyCode.uppercased() == source.currencyCode
                  }) != false,
                  let first = source.days.first,
                  let last = source.days.last
            else { return nil }
            let calendar = Self.calendar(for: source.provider)
            guard let start = Self.day(first.date, calendar: calendar),
                  let end = Self.day(last.date, calendar: calendar)
            else { return nil }
            let span = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            let daily = source.days.map(Self.entry)
            let totalCost = source.days.reduce(0.0) { $0 + $1.cost }
            let totalTokens = Self.completeIntSum(source.days.map(\.totalTokens))
            let input = SpendDashboardModel.ProviderInput(
                id: source.sourceID,
                provider: source.provider,
                displayName: source.displayName,
                modelProviderName: source.modelProviderName,
                snapshot: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: totalTokens,
                    last30DaysCostUSD: totalCost,
                    currencyCode: source.currencyCode,
                    historyDays: span,
                    // Every emitted bucket is proven by a complete provider window. The separate
                    // tracked coverage count remains authoritative when captures have calendar gaps.
                    historyCoverageIsEstablished: true,
                    historyLabel: "Tracked since \(first.date)",
                    daily: daily,
                    updatedAt: end),
                trackedCoverage: SpendDashboardModel.TrackedCoverage(
                    start: start,
                    end: end,
                    coveredDayCount: source.days.count))
            return Snapshot(
                input: input,
                coverageStart: start,
                coverageEnd: end,
                coveredDayCount: source.days.count,
                hasContinuousCoverage: source.days.count == span)
        }
        .sorted { $0.input.id < $1.input.id }
    }

    private static func dayRecord(date: String, entry: CostUsageDailyReport.Entry?) -> Day {
        guard let entry else {
            return Day(
                date: date,
                inputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                requestCount: 0,
                cost: 0,
                modelsUsed: nil,
                modelBreakdowns: [])
        }
        return Day(
            date: date,
            inputTokens: entry.inputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            outputTokens: entry.outputTokens,
            totalTokens: entry.totalTokens,
            requestCount: entry.requestCount,
            cost: entry.costUSD ?? 0,
            modelsUsed: entry.modelsUsed,
            modelBreakdowns: entry.modelBreakdowns?.map(self.modelRecord) ?? [])
    }

    private static func modelRecord(_ model: CostUsageDailyReport.ModelBreakdown) -> Model {
        Model(
            modelName: model.modelName,
            cost: model.costUSD,
            totalTokens: model.totalTokens,
            requestCount: model.requestCount,
            standardCost: model.standardCostUSD,
            priorityCost: model.priorityCostUSD,
            standardTokens: model.standardTokens,
            priorityTokens: model.priorityTokens)
    }

    private static func entry(_ day: Day) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day.date,
            inputTokens: day.inputTokens,
            outputTokens: day.outputTokens,
            cacheReadTokens: day.cacheReadTokens,
            cacheCreationTokens: day.cacheCreationTokens,
            totalTokens: day.totalTokens,
            requestCount: day.requestCount,
            costUSD: day.cost,
            modelsUsed: day.modelsUsed,
            modelBreakdowns: day.modelBreakdowns.map {
                CostUsageDailyReport.ModelBreakdown(
                    modelName: $0.modelName,
                    costUSD: $0.cost,
                    totalTokens: $0.totalTokens,
                    requestCount: $0.requestCount,
                    standardCostUSD: $0.standardCost,
                    priorityCostUSD: $0.priorityCost,
                    standardTokens: $0.standardTokens,
                    priorityTokens: $0.priorityTokens)
            })
    }

    static func ownershipScopes(
        sourceOwnershipFingerprints: [String],
        codexAccountIdentities: [String]) -> [String: String]
    {
        var result: [String: String] = [:]
        for value in sourceOwnershipFingerprints {
            guard let separator = value.firstIndex(of: ":") else { continue }
            let sourceID = String(value[..<separator])
            guard !sourceID.isEmpty else { continue }
            result[sourceID] = value
        }
        for identity in codexAccountIdentities {
            guard let separator = identity.lastIndex(of: "|") else { continue }
            let accountID = String(identity[..<separator])
            guard !accountID.isEmpty else { continue }
            result["codex:\(accountID)"] = identity
        }
        return result
    }

    private static func validAggregate(_ value: Double?) -> Bool {
        self.validCost(value) != nil
    }

    private static func validCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func completeIntSum(_ values: [Int?]) -> Int? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        var total = 0
        for value in values.compactMap(\.self) {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }

    private static func day(_ rawValue: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: rawValue), formatter.string(from: date) == rawValue else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func calendar(for provider: UsageProvider) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Provider-specific by design: Mistral daily usage buckets are defined in UTC.
        calendar.timeZone = provider == .mistral
            ? TimeZone(secondsFromGMT: 0) ?? .gmt
            : .current
        return calendar
    }

    private static func enforceOwnerOnlyPermissions(at url: URL) throws -> Bool {
        #if os(macOS)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path)
        return self.hasOwnerOnlyPermissions(at: url)
        #else
        return true
        #endif
    }

    private static func hasOwnerOnlyPermissions(at url: URL) -> Bool {
        #if os(macOS)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.intValue & 0o777 == 0o600
        #else
        return true
        #endif
    }

    nonisolated static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("spend-history.json", isDirectory: false)
    }
}
