import Foundation

package struct CodexIdentifiedSource: Codable, Sendable {
    package let host: String
    package let source: String
    package let collectedAt: Date?
    package let ledger: CodexRequestLedger?
    package let error: String?
    package var subtotal: CodexRequestSubtotal?

    enum CodingKeys: String, CodingKey { case host, source, collectedAt, ledger, error }
}

package struct CodexIdentifiedResult: Codable, Sendable {
    package let reports: [CodexIdentifiedSource]
    package let subtotal: CodexRequestSubtotal?
    package let allSourcesAvailable: Bool
    package let partial: Bool
    package var localLedgerJSON: String?

    enum CodingKeys: String, CodingKey {
        case reports, subtotal, allSourcesAvailable, partial
    }
}

package enum CodexIdentifiedCollection {
    package static func window(days: Int, endUnixMs: Int64) -> Int64? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let end = Date(timeIntervalSince1970: Double(endUnixMs) / 1000)
        guard let start = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: end)),
              start.timeIntervalSince1970 >= 0 else { return nil }
        return Int64(start.timeIntervalSince1970 * 1000)
    }

    package static func encodeJSON(_ payload: some Encodable, pretty: Bool) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        guard let data = try? encoder.encode(payload),
              let output = String(data: data, encoding: .utf8) else { return nil }
        // `print` adds one trailing newline; keep identified-ledger stdout within the SSH reader's cap.
        if payload is CodexRequestLedger, output.utf8.count >= CodexRequestLedger.maximumOutputBytes { return nil }
        return output
    }

    /// Preserve available identified requests when a source fails; cancellation prevents further SSH work.
    package static func collect(
        remotes: [String],
        startUnixMs: Int64,
        endUnixMs: Int64,
        pretty: Bool = false,
        includeSourceSubtotals: Bool = false,
        now: @Sendable () -> Date = { Date() },
        local: @Sendable () async throws -> CodexRequestLedger,
        fetchRemote: @Sendable (String) async throws -> CodexRequestLedger) async throws -> CodexIdentifiedResult
    {
        var reports: [CodexIdentifiedSource] = []
        var subtotal: CodexRequestSubtotal?
        var localLedgerJSON: String?
        let merge = remotes.isEmpty && !includeSourceSubtotals ? nil : CodexRequestLedger.makeMerger()
        let hosts = ["local"] + remotes
        for (sourceIndex, host) in hosts.enumerated() {
            try Task.checkCancellation()
            do {
                let ledger = try await (sourceIndex == 0 ? local() : fetchRemote(host))
                try Task.checkCancellation()
                try ledger.validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
                // Bound local producer output; remote bytes were already bounded by the SSH reader.
                if sourceIndex == 0 {
                    guard let json = Self.encodeJSON(ledger, pretty: pretty) else {
                        throw RemoteCodexCostError.invalidReport
                    }
                    if remotes.isEmpty { localLedgerJSON = json }
                }
                if !remotes.isEmpty, let merge {
                    // Reject an overflowing union while the earlier sources remain available.
                    subtotal = try merge(reports.compactMap(\.ledger) + [ledger])
                }
                reports.append(.init(
                    host: host,
                    source: sourceIndex == 0 ? "local" : "ssh",
                    collectedAt: now(),
                    ledger: ledger,
                    error: nil,
                    subtotal: includeSourceSubtotals
                        ? (sourceIndex == 0 ? subtotal : nil) ?? (try? merge?([ledger]))
                        : nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                reports.append(.init(
                    host: host,
                    source: sourceIndex == 0 ? "local" : "ssh",
                    collectedAt: nil,
                    ledger: nil,
                    error: sourceIndex == 0
                        ? "Local native Codex identified usage is unavailable."
                        :
                        "Remote identified usage is unavailable. Check SSH and update its CLI " +
                        "for schema 2 --identified-only."))
            }
        }
        try Task.checkCancellation()
        let available = reports.allSatisfy { $0.ledger != nil }
        return CodexIdentifiedResult(
            reports: reports,
            subtotal: subtotal,
            allSourcesAvailable: available,
            partial: !available || (subtotal?.partial ?? false),
            localLedgerJSON: localLedgerJSON)
    }
}
