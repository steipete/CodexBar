import Crypto
import Foundation

/// Only accounting and pricing differ between providers; transport and collection share these limits.
package protocol IdentifiedRequestLedger: Codable, Sendable {
    static var providerName: String { get }
    static var supportedSchemaVersion: Int { get }
    var schemaVersion: Int { get }
    var provider: String { get }
    var startUnixMs: Int64 { get }
    var endUnixMs: Int64 { get }
    var conflictingIDs: [String] { get }
    var excludedCount: Int { get }
    func validate(startUnixMs: Int64, endUnixMs: Int64) throws
    static func makeMerger() -> ([Self]) throws -> CodexRequestSubtotal
}

package enum IdentifiedRequestLimits {
    package static let maximumRecords = 50000
    package static let maximumOutputBytes = 32 * 1024 * 1024
    package static let maximumSources = 16
    package static let maximumCollectionBytes = 128 * 1024 * 1024
}

extension IdentifiedRequestLedger {
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func digest(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func validateEnvelope(startUnixMs: Int64, endUnixMs: Int64, recordCount: Int) throws {
        guard self.schemaVersion == Self.supportedSchemaVersion, self.provider == Self.providerName,
              self.startUnixMs == startUnixMs, self.endUnixMs == endUnixMs,
              startUnixMs >= 0, endUnixMs <= 253_402_300_799_999, endUnixMs >= startUnixMs,
              startUnixMs % 86_400_000 == 0, endUnixMs - startUnixMs < 365 * 86_400_000,
              recordCount <= IdentifiedRequestLimits.maximumRecords,
              self.conflictingIDs.count <= IdentifiedRequestLimits.maximumRecords,
              self.excludedCount >= 0, Set(self.conflictingIDs).count == self.conflictingIDs.count,
              self.conflictingIDs.allSatisfy(Self.isDigest)
        else { throw RemoteCodexCostError.invalidReport }
    }
}

extension CodexRequestLedger: IdentifiedRequestLedger {
    // Provider-specific by design: preserve the released Codex wire discriminator.
    package static let providerName = "codex"
    package static let supportedSchemaVersion = 2
}

extension PiRequestLedger: IdentifiedRequestLedger {
    // Provider-specific by design: Pi and OMP share a native session identity namespace.
    package static let providerName = "pi"
    package static let supportedSchemaVersion = 2
}

package struct IdentifiedSource<Ledger: IdentifiedRequestLedger>: Codable, Sendable {
    package let host: String
    package let source: String
    package let collectedAt: Date?
    package let ledger: Ledger?
    package let error: String?
}

package struct IdentifiedResult<Ledger: IdentifiedRequestLedger>: Codable, Sendable {
    package let reports: [IdentifiedSource<Ledger>]
    package let subtotal: CodexRequestSubtotal?
    package let allSourcesAvailable: Bool
    package let partial: Bool
    package var localLedgerJSON: String?

    enum CodingKeys: String, CodingKey { case reports, subtotal, allSourcesAvailable, partial }
}

package enum IdentifiedCostCollection {
    /// Validate every destination before even the local scan, and retain only bounded, validated exports.
    package static func collect<Ledger: IdentifiedRequestLedger>(
        remotes: [String],
        startUnixMs: Int64,
        endUnixMs: Int64,
        pretty: Bool = false,
        now: @Sendable () -> Date = { Date() },
        local: @Sendable () async throws -> Ledger,
        fetchRemote: @Sendable (String) async throws -> Ledger) async throws -> IdentifiedResult<Ledger>
    {
        guard remotes.count < IdentifiedRequestLimits.maximumSources else {
            throw RemoteCodexCostError.invalidReport
        }
        for host in remotes {
            try RemoteCodexCostFetcher.validateHost(host)
        }
        var reports: [IdentifiedSource<Ledger>] = []
        var subtotal: CodexRequestSubtotal?
        var localLedgerJSON: String?
        var retainedBytes = 0
        let merge = remotes.isEmpty ? nil : Ledger.makeMerger()
        for (index, host) in (["local"] + remotes).enumerated() {
            try Task.checkCancellation()
            do {
                let ledger = try await (index == 0 ? local() : fetchRemote(host))
                try Task.checkCancellation()
                try ledger.validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
                let encoder = JSONEncoder()
                encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
                let data = try encoder.encode(ledger)
                // Remote byte limits apply to received JSON; re-encoding can expand escaping.
                guard index != 0 || data.count < IdentifiedRequestLimits.maximumOutputBytes,
                      retainedBytes + data.count <= IdentifiedRequestLimits.maximumCollectionBytes
                else { throw RemoteCodexCostError.invalidReport }
                if let merge { subtotal = try merge(reports.compactMap(\.ledger) + [ledger]) }
                retainedBytes += data.count
                if index == 0, remotes.isEmpty { localLedgerJSON = String(data: data, encoding: .utf8) }
                reports.append(.init(
                    host: host, source: index == 0 ? "local" : "ssh", collectedAt: now(), ledger: ledger, error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                reports.append(.init(
                    host: host,
                    source: index == 0 ? "local" : "ssh",
                    collectedAt: nil,
                    ledger: nil,
                    error: (index == 0
                        ? "Local native \(Ledger.providerName.capitalized) identified usage is unavailable. "
                        :
                        "Remote \(Ledger.providerName.capitalized) identified usage is unavailable. " +
                        "Check SSH and update its CLI " +
                        "for schema \(Ledger.supportedSchemaVersion) --identified-only. ") +
                        "For large histories, try fewer --days; exports are limited to 50,000 records and 32 MiB, " +
                        "with 128 MiB retained across sources."))
            }
        }
        try Task.checkCancellation()
        let available = reports.allSatisfy { $0.ledger != nil }
        return .init(
            reports: reports,
            subtotal: subtotal,
            allSourcesAvailable: available,
            partial: !available || (subtotal?.partial ?? false),
            localLedgerJSON: localLedgerJSON)
    }
}
