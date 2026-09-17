import Foundation

/// The scanner and its recursive ancestor index see only these validated canonical copies.
/// Comparison preserves every record byte and occurrence, including non-usage records.
enum CodexCombinedLogPreparation {
    struct Prepared {
        let roots: [URL]
        let priority: CodexCombinedPriorityEvidence
    }

    struct Session {
        let data: Data
        let source: URL
        let records: [Data]
        let id: String
        let parent: String?
        let turnIDs: Set<String>
        let rootIndex: Int
    }

    static let maxBytes = 512 * 1024 * 1024
    static let maxFileBytes = 256 * 1024 * 1024
    static let maxFiles = 10000

    static func prepare(
        roots: [URL],
        destination: URL,
        localRootCount: Int = 2,
        ownedRemoteDirectory: URL? = nil,
        localTraceURL: URL? = nil,
        since: Date? = nil,
        until: Date? = nil,
        calendar: Calendar = .current,
        retainedPriority: CodexCombinedPriorityEvidence = .init(),
        checkCancellation: @escaping @Sendable () throws -> Void) throws -> Prepared
    {
        let manager = FileManager.default
        var sessions: [String: Session] = [:]
        var localTurns: [String: Set<String>] = [:]
        var priority = retainedPriority
        var retainedPaths = Set(priority.retainedSessionsByPath.keys)
        var bytes = 0
        var count = 0
        var remoteFiles = Set<URL>()
        for (index, root) in roots.enumerated() {
            for file in try self.files(root: root, checkCancellation: checkCancellation) {
                try checkCancellation()
                if index >= localRootCount, let ownedRemoteDirectory {
                    guard file.standardizedFileURL.path.hasPrefix(ownedRemoteDirectory.standardizedFileURL.path + "/")
                    else { throw CodexCombinedCostError.unsafeLocalLogs }
                    remoteFiles.insert(file)
                }
                count += 1
                guard count <= Self.maxFiles else { throw CodexCombinedCostError.unsafeLocalLogs }
                let before = try manager.attributesOfItem(atPath: file.path)
                let size = (before[.size] as? NSNumber)?.intValue ?? -1
                guard size >= 0, size <= Self.maxFileBytes, bytes <= Self.maxBytes - size else {
                    throw CodexCombinedCostError.unsafeLocalLogs
                }
                // Read the bounded advertised size plus one, so a growing local file cannot allocate without limit.
                let handle = try FileHandle(forReadingFrom: file)
                let data: Data
                do {
                    data = try handle.read(upToCount: size + 1) ?? Data()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw CodexCombinedCostError.unsafeLocalLogs
                }
                let after = try manager.attributesOfItem(atPath: file.path)
                guard data.count == size,
                      before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                      before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
                      before[.size] as? NSNumber == after[.size] as? NSNumber
                else { throw CodexCombinedCostError.unsafeLocalLogs }
                bytes += size
                guard !data.isEmpty else { continue }
                let session = try self.session(
                    data: data,
                    source: file,
                    rootIndex: index,
                    checkCancellation: checkCancellation)
                if index < localRootCount {
                    localTurns[session.id, default: []].formUnion(session.turnIDs)
                    let path = file.resolvingSymlinksInPath().path
                    if let retainedID = priority.retainedSessionsByPath[path] {
                        guard retainedID == session.id else { throw CodexCombinedCostError.pricingEvidence }
                        retainedPaths.remove(path)
                    }
                }
                if let previous = sessions[session.id] {
                    let shorter = previous.records.count <= session.records.count ? previous : session
                    let longer = previous.records.count <= session.records.count ? session : previous
                    guard longer.records.starts(with: shorter.records) else {
                        throw CodexCombinedCostError.unsupportedOverlap
                    }
                    sessions[session.id] = longer
                } else {
                    sessions[session.id] = session
                }
            }
        }
        guard retainedPaths.isEmpty else { throw CodexCombinedCostError.pricingEvidence }
        try priority.resolveTrace(
            at: localTraceURL,
            localTurns: localTurns,
            since: since,
            until: until,
            calendar: calendar)
        for session in sessions.values {
            var visited: Set<String> = [session.id]
            var parent = session.parent
            while let id = parent {
                guard visited.insert(id).inserted, let ancestor = sessions[id] else {
                    throw CodexCombinedCostError.missingAncestor
                }
                parent = ancestor.parent
            }
        }
        let canonicalRoots = try self.materialize(
            sessions: sessions,
            rootCount: roots.count,
            remoteFiles: remoteFiles,
            destination: destination,
            checkCancellation: checkCancellation)
        return Prepared(roots: canonicalRoots, priority: priority)
    }

    private static func materialize(
        sessions: [String: Session],
        rootCount: Int,
        remoteFiles: Set<URL>,
        destination: URL,
        checkCancellation: @escaping @Sendable () throws -> Void) throws -> [URL]
    {
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let canonicalRoots = (0..<rootCount).map { destination.appendingPathComponent("root-\($0)", isDirectory: true) }
        for root in canonicalRoots {
            try manager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        // Remove redundant received copies before materializing local-only records. Selected remote files move,
        // so received + canonical raw bytes never exceed the validated combined input budget.
        let selectedSources = Set(sessions.values.map(\.source))
        for file in remoteFiles.subtracting(selectedSources) {
            try manager.removeItem(at: file)
        }
        let orderedIDs = sessions.keys.sorted { left, right in
            let leftRemote = sessions[left].map { remoteFiles.contains($0.source) } ?? false
            let rightRemote = sessions[right].map { remoteFiles.contains($0.source) } ?? false
            return leftRemote == rightRemote ? left < right : leftRemote
        }
        for (index, id) in orderedIDs.enumerated() {
            try checkCancellation()
            guard let session = sessions[id] else { continue }
            let target = canonicalRoots[session.rootIndex].appendingPathComponent("session-\(index).jsonl")
            if remoteFiles.contains(session.source) {
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.moveItem(at: session.source, to: target)
            } else {
                guard manager.createFile(
                    atPath: target.path, contents: session.data, attributes: [.posixPermissions: 0o600])
                else { throw CodexCombinedCostError.unsafeLocalLogs }
            }
        }
        return canonicalRoots
    }

    private static func files(
        root: URL,
        checkCancellation: @escaping @Sendable () throws -> Void) throws -> [URL]
    {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: root.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw CodexCombinedCostError.unsafeLocalLogs
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CodexCombinedCostError.unsafeLocalLogs
        }
        var pending = [root]
        var files: [URL] = []
        while let directory = pending.popLast() {
            try checkCancellation()
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: pending.append(url)
                case .typeRegular:
                    if url.pathExtension == "jsonl" { files.append(url) }
                default: throw CodexCombinedCostError.unsafeLocalLogs
                }
                guard pending.count + files.count <= Self.maxFiles else {
                    throw CodexCombinedCostError.unsafeLocalLogs
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func session(
        data: Data,
        source: URL,
        rootIndex: Int,
        checkCancellation: @escaping @Sendable () throws -> Void) throws -> Session
    {
        // A non-terminated tail might still be being written. Never infer a safe cutoff.
        guard data.last == 10 else { throw CodexCombinedCostError.unsupportedOverlap }
        let records = data.split(separator: 10, omittingEmptySubsequences: false).dropLast().map { Data($0) }
        var id: String?
        var parent: String?
        var turnIDs = Set<String>()
        for (index, record) in records.enumerated() {
            try checkCancellation()
            guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                  let type = object["type"] as? String
            else { throw CodexCombinedCostError.unsupportedOverlap }
            if Self.hasUnsupportedPricingEvidence(object) { throw CodexCombinedCostError.pricingEvidence }
            let requiresUsageIdentity = try Self.requiresUsageIdentity(object)
            let nativeLine = CostUsageScanner.parseCodexFastLine(record)
            if record.count > CostUsageScanner.codexSessionMetadataMaxLineBytes,
               nativeLine != nil || CostUsageScanner.codexBareUsage(from: object) != nil
            {
                // Native data readers skip oversized lines. Never publish an omitted usage/state record as zero.
                throw CodexCombinedCostError.unsupportedOverlap
            }
            switch nativeLine {
            case let .sessionMeta(metadata):
                guard type == "session_meta", index == 0, let identity = metadata.sessionId, !identity.isEmpty else {
                    throw CodexCombinedCostError.unsupportedOverlap
                }
                if let timestamp = metadata.forkTimestamp, CostUsageScanner.dateFromTimestamp(timestamp) == nil {
                    throw CodexCombinedCostError.missingAncestor
                }
                if metadata.forkedFromId != nil, metadata.forkTimestamp == nil {
                    throw CodexCombinedCostError.missingAncestor
                }
                // Inferred subagent lineage is outside the verified explicit-parent shape.
                if metadata.isSubagentThread, metadata.forkedFromId == nil {
                    throw CodexCombinedCostError.missingAncestor
                }
                id = identity
                parent = metadata.forkedFromId
            case let .taskStarted(turnID):
                if let turnID { turnIDs.insert(turnID) }
            case let .tokenCount(record):
                guard CostUsageScanner.dateFromTimestamp(record.timestamp) != nil else {
                    throw CodexCombinedCostError.unsupportedOverlap
                }
                if let turnID = record.turnID { turnIDs.insert(turnID) }
            default:
                if type == "session_meta" || requiresUsageIdentity {
                    throw CodexCombinedCostError.unsupportedOverlap
                }
            }
        }
        guard let id else { throw CodexCombinedCostError.unsupportedOverlap }
        return Session(
            data: data,
            source: source,
            records: records,
            id: id,
            parent: parent,
            turnIDs: turnIDs,
            rootIndex: rootIndex)
    }

    /// Reject timestamp/fallback shapes that could bypass the shared fast-line identity or log raw ancestry text.
    private static func requiresUsageIdentity(_ object: [String: Any]) throws -> Bool {
        guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] else {
            return false
        }
        if payload["type"] as? String == "task_started" {
            // The native reader skips state events without a valid outer timestamp. Retaining their
            // turn IDs only in the preparation index would detach Priority evidence from usage rows.
            guard let timestamp = object["timestamp"] as? String,
                  CostUsageScanner.dateFromTimestamp(timestamp) != nil
            else { throw CodexCombinedCostError.unsupportedOverlap }
            return true
        }
        guard payload["type"] as? String == "token_count", payload["info"] is [String: Any] else { return false }
        guard let timestamp = object["timestamp"] as? String,
              CostUsageScanner.dateFromTimestamp(timestamp) != nil
        else { throw CodexCombinedCostError.unsupportedOverlap }
        return true
    }

    private static func hasUnsupportedPricingEvidence(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String,
              ["session_meta", "turn_context", "event_msg"].contains(type) else { return false }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let info = payload["info"] as? [String: Any] ?? [:]
        return [object, payload, info].contains { fields in
            ["service_tier", "serviceTier", "pricing_mode", "pricingMode"].contains { key in
                guard let mode = fields[key] as? String else { return false }
                return ["priority", "fast"].contains(mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
    }
}
