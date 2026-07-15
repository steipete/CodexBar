#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Pass-one lineage index. It retains file identity and quality evidence, never token observations.
enum CodexLineageTwoPassDiscovery {
    enum DiscoveryError: Error, Equatable {
        case fileChangedDuringScan
    }

    struct FileSignature: Equatable, Hashable, Sendable {
        let size: Int64
        let modifiedMilliseconds: Int64
        let contentSHA256: String
    }

    struct Descriptor: Equatable, Sendable {
        let fileURL: URL
        let ownerID: String
        let metadataSessionID: String?
        let parentSessionID: String?
        let scopeID: String
        let incompleteObservationCount: Int
        let observationCount: Int
        let signature: FileSignature
    }

    struct Report: Equatable, Sendable {
        let descriptors: [Descriptor]
        let referencedParentDocumentCount: Int
        let unresolvedParents: Set<CodexLineageLedger.ParentIdentity>
        let peakRetainedObservationCount: Int
    }

    static func discover(
        includedFiles: [URL],
        roots: [URL],
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Report
    {
        var locator = ParentLocator(roots: roots, checkCancellation: checkCancellation)
        var descriptors: [Descriptor] = []
        var known: Set<ScopedIdentity> = []
        var pending: [ScopedIdentity] = []
        var unresolved: Set<CodexLineageLedger.ParentIdentity> = []
        var seenPaths: Set<String> = []
        var referencedParents = 0

        func remember(_ descriptor: Descriptor) {
            descriptors.append(descriptor)
            known.insert(.init(scopeID: descriptor.scopeID, sessionID: Self.canonical(descriptor.ownerID)))
            if let parent = Self.nonEmpty(descriptor.parentSessionID) {
                pending.append(.init(scopeID: descriptor.scopeID, sessionID: Self.canonical(parent)))
            }
        }

        for fileURL in includedFiles.sorted(by: { $0.path < $1.path }) {
            try checkCancellation?()
            guard seenPaths.insert(fileURL.standardizedFileURL.path).inserted else { continue }
            try remember(Self.describe(fileURL: fileURL, checkCancellation: checkCancellation))
        }

        var nextParent = 0
        while nextParent < pending.count {
            try checkCancellation?()
            let identity = pending[nextParent]
            nextParent += 1
            let unresolvedIdentity = CodexLineageLedger.ParentIdentity(
                scopeID: identity.scopeID,
                sessionID: identity.sessionID)
            guard !known.contains(identity), !unresolved.contains(unresolvedIdentity) else { continue }
            guard let matches = try locator.fileURLs(for: identity) else {
                unresolved.insert(unresolvedIdentity)
                continue
            }
            var found = false
            for fileURL in matches {
                try checkCancellation?()
                guard seenPaths.insert(fileURL.standardizedFileURL.path).inserted else { continue }
                let descriptor = try Self.describe(fileURL: fileURL, checkCancellation: checkCancellation)
                let identities = [descriptor.ownerID, descriptor.metadataSessionID]
                    .compactMap(Self.nonEmpty)
                    .map(Self.canonical)
                guard identities.contains(identity.sessionID) else { continue }
                remember(descriptor)
                referencedParents += 1
                found = true
            }
            if !found {
                unresolved.insert(unresolvedIdentity)
            }
        }

        return Report(
            descriptors: descriptors.sorted { $0.fileURL.path < $1.fileURL.path },
            referencedParentDocumentCount: referencedParents,
            unresolvedParents: unresolved,
            peakRetainedObservationCount: 0)
    }

    static func describe(
        fileURL: URL,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Descriptor
    {
        // Validate both sides of the parse. A post-parse signature alone can bless a
        // mixed read when a rollout is replaced while the parser has the file open.
        let initialSignature = try Self.signature(fileURL: fileURL, checkCancellation: checkCancellation)
        let parsed = try CostUsageScanner.parseCodexLineageDocumentSummaryWithSHA256(
            fileURL: fileURL,
            checkCancellation: checkCancellation)
        let finalSignature = try Self.signatureMetadata(fileURL: fileURL, contentSHA256: parsed.sha256)
        guard initialSignature == finalSignature else { throw DiscoveryError.fileChangedDuringScan }
        return Descriptor(
            fileURL: fileURL,
            ownerID: parsed.summary.ownerID,
            metadataSessionID: parsed.summary.metadataSessionID,
            parentSessionID: parsed.summary.parentSessionID,
            scopeID: parsed.summary.scopeID,
            incompleteObservationCount: parsed.summary.incompleteObservationCount,
            observationCount: parsed.summary.observationCount,
            signature: finalSignature)
    }

    static func loadDocument(
        _ descriptor: Descriptor,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CodexLineageLedger.Document
    {
        let parsed = try CostUsageScanner.parseCodexLineageDocumentWithSHA256(
            fileURL: descriptor.fileURL,
            checkCancellation: checkCancellation)
        guard try Self.signatureMetadata(fileURL: descriptor.fileURL, contentSHA256: parsed.sha256) == descriptor
            .signature
        else { throw DiscoveryError.fileChangedDuringScan }
        return parsed.document
    }

    private static func signature(
        fileURL: URL,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> FileSignature
    {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try checkCancellation?()
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileSignature(
            size: Int64(values.fileSize ?? 0),
            modifiedMilliseconds: Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000),
            contentSHA256: digest)
    }

    private static func signatureMetadata(fileURL: URL, contentSHA256: String) throws -> FileSignature {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileSignature(
            size: Int64(values.fileSize ?? 0),
            modifiedMilliseconds: Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000),
            contentSHA256: contentSHA256)
    }

    private struct ScopedIdentity: Equatable, Hashable {
        let scopeID: String
        let sessionID: String
    }

    private struct ParentLocator {
        let roots: [URL]
        let checkCancellation: CostUsageScanner.CancellationCheck?
        var indexed = false
        var filesByIdentity: [ScopedIdentity: Set<URL>] = [:]

        mutating func fileURLs(for identity: ScopedIdentity) throws -> [URL]? {
            if !self.indexed {
                try self.index()
            }
            guard let matches = self.filesByIdentity[identity], !matches.isEmpty else { return nil }
            let exactOwnerMatches = matches.filter {
                CostUsageScanner.codexRolloutOwnerID(fileURL: $0)
                    .map(CodexLineageTwoPassDiscovery.canonical) == identity.sessionID
            }
            if !exactOwnerMatches.isEmpty {
                return exactOwnerMatches.sorted { $0.path < $1.path }
            }
            let owners = Set(matches.compactMap(CostUsageScanner.codexRolloutOwnerID(fileURL:)))
            guard matches.count == 1 || owners.count == 1 else { return nil }
            return matches.sorted { $0.path < $1.path }
        }

        private mutating func index() throws {
            self.indexed = true
            for root in self.roots {
                try self.checkCancellation?()
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                else { continue }
                while let fileURL = enumerator.nextObject() as? URL {
                    try self.checkCancellation?()
                    guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                    let scopeID = CostUsageScanner.codexLineageScopeID(fileURL: fileURL)
                    if let owner = CostUsageScanner.codexRolloutOwnerID(fileURL: fileURL) {
                        self.filesByIdentity[
                            .init(scopeID: scopeID, sessionID: CodexLineageTwoPassDiscovery.canonical(owner)),
                            default: [],
                        ].insert(fileURL)
                    }
                    if let sessionID = try CostUsageScanner.parseCodexSessionIdentifier(
                        fileURL: fileURL,
                        checkCancellation: self.checkCancellation)
                    {
                        self.filesByIdentity[
                            .init(scopeID: scopeID, sessionID: CodexLineageTwoPassDiscovery.canonical(sessionID)),
                            default: [],
                        ].insert(fileURL)
                    }
                }
            }
        }
    }

    private static func canonical(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
