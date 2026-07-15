import Foundation

/// Expands an already bounded rollout-file selection with only the ancestors its documents reference.
enum CodexLineageDiscovery {
    struct Report: Equatable, Sendable {
        let documents: [CodexLineageLedger.Document]
        let referencedParentDocumentCount: Int
        let unresolvedParents: Set<CodexLineageLedger.ParentIdentity>
    }

    static func discover(
        includedFiles: [URL],
        roots: [URL],
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Report
    {
        var locator = ParentFileLocator(roots: roots, checkCancellation: checkCancellation)
        var documents: [CodexLineageLedger.Document] = []
        var knownIDs: Set<ScopedIdentity> = []
        var seenPaths: Set<String> = []
        var pendingParentIDs: [ScopedIdentity] = []
        var unresolvedParents: Set<CodexLineageLedger.ParentIdentity> = []
        var referencedParentDocumentCount = 0

        func remember(_ document: CodexLineageLedger.Document) {
            documents.append(document)
            knownIDs.insert(.init(scopeID: document.scopeID, sessionID: Self.canonicalSessionID(document.ownerID)))
            if let parentSessionID = Self.nonEmpty(document.parentSessionID) {
                pendingParentIDs.append(.init(
                    scopeID: document.scopeID,
                    sessionID: Self.canonicalSessionID(parentSessionID)))
            }
        }

        for fileURL in includedFiles.sorted(by: { $0.path < $1.path }) {
            try checkCancellation?()
            let path = fileURL.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            try remember(CostUsageScanner.parseCodexLineageDocument(
                fileURL: fileURL,
                checkCancellation: checkCancellation))
        }

        var nextParent = 0
        while nextParent < pendingParentIDs.count {
            try checkCancellation?()
            let parentIdentity = pendingParentIDs[nextParent]
            nextParent += 1
            let unresolvedIdentity = CodexLineageLedger.ParentIdentity(
                scopeID: parentIdentity.scopeID,
                sessionID: parentIdentity.sessionID)
            guard !knownIDs.contains(parentIdentity), !unresolvedParents.contains(unresolvedIdentity) else {
                continue
            }
            guard let parentURLs = try locator.fileURLs(
                for: parentIdentity.sessionID,
                scopeID: parentIdentity.scopeID)
            else {
                unresolvedParents.insert(unresolvedIdentity)
                continue
            }
            var foundParent = false
            for parentURL in parentURLs {
                let path = parentURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                let parent = try CostUsageScanner.parseCodexLineageDocument(
                    fileURL: parentURL,
                    checkCancellation: checkCancellation)
                let ownerID = Self.canonicalSessionID(parent.ownerID)
                guard ownerID == parentIdentity.sessionID else {
                    continue
                }
                referencedParentDocumentCount += 1
                foundParent = true
                remember(parent)
            }
            if !foundParent {
                unresolvedParents.insert(unresolvedIdentity)
            }
        }

        return Report(
            documents: documents,
            referencedParentDocumentCount: referencedParentDocumentCount,
            unresolvedParents: unresolvedParents)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func canonicalSessionID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private struct ScopedIdentity: Equatable, Hashable {
        let scopeID: String
        let sessionID: String
    }

    private struct ParentFileLocator {
        let roots: [URL]
        let checkCancellation: CostUsageScanner.CancellationCheck?
        var didIndexRoots = false
        var filesByID: [ScopedIdentity: Set<URL>] = [:]

        mutating func fileURLs(for sessionID: String, scopeID: String) throws -> [URL]? {
            let canonicalID = CodexLineageDiscovery.canonicalSessionID(sessionID)
            let key = ScopedIdentity(scopeID: scopeID, sessionID: canonicalID)
            if let known = self.filesByID[key] {
                return Self.unambiguousMatches(known)
            }
            if !self.didIndexRoots {
                try self.indexRoots()
            }
            guard let matches = self.filesByID[key] else { return nil }
            return Self.unambiguousMatches(matches)
        }

        private static func unambiguousMatches(_ matches: Set<URL>) -> [URL]? {
            guard !matches.isEmpty else { return nil }
            if matches.count == 1 {
                return Array(matches)
            }
            let ownerIDs = Set(matches.compactMap(CostUsageScanner.codexRolloutOwnerID(fileURL:)))
            guard ownerIDs.count == 1 else { return nil }
            return matches.sorted { $0.path < $1.path }
        }

        private mutating func indexRoots() throws {
            self.didIndexRoots = true
            var files: [URL] = []
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
                    files.append(fileURL)
                }
            }

            for fileURL in files.sorted(by: { $0.path < $1.path }) {
                try self.checkCancellation?()
                if let ownerID = CostUsageScanner.codexRolloutOwnerID(fileURL: fileURL) {
                    let canonicalID = CodexLineageDiscovery.canonicalSessionID(ownerID)
                    let key = ScopedIdentity(
                        scopeID: CostUsageScanner.codexLineageScopeID(fileURL: fileURL),
                        sessionID: canonicalID)
                    self.filesByID[key, default: []].insert(fileURL)
                }
            }
        }
    }
}
