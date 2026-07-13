import Foundation

/// Expands an already bounded rollout-file selection with only the ancestors its documents reference.
enum CodexLineageDiscovery {
    struct Report: Equatable, Sendable {
        let documents: [CodexLineageLedger.Document]
        let referencedParentDocumentCount: Int
        let unresolvedParentIDs: Set<String>
    }

    static func discover(
        includedFiles: [URL],
        roots: [URL],
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Report
    {
        var locator = ParentFileLocator(roots: roots, checkCancellation: checkCancellation)
        var documents: [CodexLineageLedger.Document] = []
        var knownIDs: Set<String> = []
        var seenPaths: Set<String> = []
        var pendingParentIDs: [String] = []
        var unresolvedParentIDs: Set<String> = []
        var referencedParentDocumentCount = 0

        func remember(_ document: CodexLineageLedger.Document) {
            documents.append(document)
            knownIDs.insert(Self.canonicalSessionID(document.ownerID))
            if let metadataSessionID = Self.nonEmpty(document.metadataSessionID) {
                knownIDs.insert(Self.canonicalSessionID(metadataSessionID))
            }
            if let parentSessionID = Self.nonEmpty(document.parentSessionID) {
                pendingParentIDs.append(Self.canonicalSessionID(parentSessionID))
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
            let parentID = pendingParentIDs[nextParent]
            nextParent += 1
            guard !knownIDs.contains(parentID), !unresolvedParentIDs.contains(parentID) else { continue }
            guard let parentURL = try locator.fileURL(for: parentID) else {
                unresolvedParentIDs.insert(parentID)
                continue
            }
            let path = parentURL.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else {
                unresolvedParentIDs.insert(parentID)
                continue
            }
            let parent = try CostUsageScanner.parseCodexLineageDocument(
                fileURL: parentURL,
                checkCancellation: checkCancellation)
            let ownerID = Self.canonicalSessionID(parent.ownerID)
            let metadataSessionID = parent.metadataSessionID.map(Self.canonicalSessionID)
            guard ownerID == parentID || metadataSessionID == parentID else {
                unresolvedParentIDs.insert(parentID)
                continue
            }
            referencedParentDocumentCount += 1
            remember(parent)
        }

        return Report(
            documents: documents,
            referencedParentDocumentCount: referencedParentDocumentCount,
            unresolvedParentIDs: unresolvedParentIDs)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func canonicalSessionID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private struct ParentFileLocator {
        let roots: [URL]
        let checkCancellation: CostUsageScanner.CancellationCheck?
        var didIndexRoots = false
        var filesByID: [String: URL] = [:]

        mutating func fileURL(for sessionID: String) throws -> URL? {
            let canonicalID = CodexLineageDiscovery.canonicalSessionID(sessionID)
            if let known = self.filesByID[canonicalID] {
                return known
            }
            if !self.didIndexRoots {
                try self.indexRoots()
            }
            return self.filesByID[canonicalID]
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
                    self.filesByID[canonicalID] = self.filesByID[canonicalID] ?? fileURL
                }
                if let metadataID = try CostUsageScanner.parseCodexSessionIdentifier(
                    fileURL: fileURL,
                    checkCancellation: self.checkCancellation)
                {
                    let canonicalID = CodexLineageDiscovery.canonicalSessionID(metadataID)
                    self.filesByID[canonicalID] = self.filesByID[canonicalID] ?? fileURL
                }
            }
        }
    }
}
