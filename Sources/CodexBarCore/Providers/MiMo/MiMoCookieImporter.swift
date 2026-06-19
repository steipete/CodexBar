import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum MiMoCookieHeader {
    static let requiredCookieNames: Set<String> = [
        "api-platform_serviceToken",
        "userId",
    ]
    static let knownCookieNames: Set<String> = requiredCookieNames.union([
        "api-platform_ph",
        "api-platform_slh",
    ])

    static func normalizedHeader(from raw: String?) -> String? {
        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        let pairs = CookieHeaderNormalizer.pairs(from: normalized)
        guard !pairs.isEmpty else { return nil }

        var byName: [String: String] = [:]
        for pair in pairs {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.knownCookieNames.contains(name), !value.isEmpty else { continue }
            byName[name] = value
        }

        guard self.requiredCookieNames.isSubset(of: Set(byName.keys)) else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let value = byName[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }

    static func header(from cookies: [HTTPCookie]) -> String? {
        let requestURL = URL(string: "https://platform.xiaomimimo.com/api/v1/balance")!
        var byName: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard self.knownCookieNames.contains(cookie.name) else { continue }
            guard !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let expiry = cookie.expiresDate, expiry < Date() { continue }
            guard Self.matchesRequestURL(cookie: cookie, url: requestURL) else { continue }

            if let existing = byName[cookie.name] {
                if Self.cookieSortKey(for: cookie) >= Self.cookieSortKey(for: existing) {
                    byName[cookie.name] = cookie
                }
            } else {
                byName[cookie.name] = cookie
            }
        }

        guard self.requiredCookieNames.isSubset(of: Set(byName.keys)) else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let cookie = byName[name] else { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }.joined(separator: "; ")
    }

    private static func matchesRequestURL(cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host else { return false }
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedDomain.isEmpty else { return false }
        guard host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") else { return false }

        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath == cookiePath {
            return true
        }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        guard cookiePath != "/" else { return true }
        if cookiePath.hasSuffix("/") {
            return true
        }
        guard
            let boundaryIndex = requestPath.index(
                cookiePath.startIndex,
                offsetBy: cookiePath.count,
                limitedBy: requestPath.endIndex),
            boundaryIndex < requestPath.endIndex
        else {
            return true
        }
        return requestPath[boundaryIndex] == "/"
    }

    private static func cookieSortKey(for cookie: HTTPCookie) -> (Int, Int, Date) {
        let pathLength = cookie.path.count
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainLength = normalizedDomain.count
        let expiry = cookie.expiresDate ?? .distantPast
        return (pathLength, domainLength, expiry)
    }
}

#if os(macOS)
import SweetCookieKit

private let miMoCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.mimo]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum MiMoCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.mimoCookie)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "platform.xiaomimimo.com",
        "xiaomimimo.com",
    ]

    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String

        public init(cookieHeader: String, sourceLabel: String) {
            self.cookieHeader = cookieHeader
            self.sourceLabel = sourceLabel
        }
    }

    nonisolated(unsafe) static var importSessionsOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo])?

    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        if let override = self.importSessionsOverrideForTesting {
            return try override(browserDetection, logger)
        }

        return try self.importSessions(
            browserDetection: browserDetection,
            logger: logger,
            loadRecords: { browserSource, query, log in
                try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
            })
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil,
        loadRecords: (Browser, BrowserCookieQuery, ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords]) throws -> [SessionInfo]
    {
        try self.importSessions(
            browserDetection: browserDetection,
            logger: logger,
            loadRecords: loadRecords,
            loadStores: { try self.cookieClient.codexBarStores(for: $0) })
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil,
        loadRecords: (Browser, BrowserCookieQuery, ((String) -> Void)?) throws
            -> [BrowserCookieStoreRecords],
        loadStores: (Browser) throws -> [BrowserCookieStore]) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in
            logger?("[mimo-cookie] \(msg)")
            Self.log.debug("\(msg)")
        }
        var sessions: [SessionInfo] = []
        var accessDeniedHints: [String] = []
        let installed = miMoCookieImportOrder.cookieImportCandidates(using: browserDetection)
        let labels = installed.map(\.displayName).joined(separator: ", ")
        log("Cookie import candidates: \(labels)")

        for browserSource in installed {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try loadRecords(browserSource, query, log)
                let stores = browserSource.usesGeckoProfileStore ? try loadStores(browserSource) : []
                let resolvedSources = self.recordsIncludingFirefoxSessionCookies(
                    from: sources,
                    browser: browserSource,
                    stores: stores,
                    logger: log)
                let recordCount = sources.reduce(0) { $0 + $1.records.count }
                let resolvedRecordCount = resolvedSources.reduce(0) { $0 + $1.records.count }
                if resolvedRecordCount == recordCount {
                    log("\(browserSource.displayName): \(sources.count) store(s), \(recordCount) record(s)")
                } else {
                    log(
                        "\(browserSource.displayName): \(sources.count) store(s), " +
                            "\(recordCount) persisted record(s), \(resolvedRecordCount) " +
                            "record(s) after session restore")
                }
                sessions.append(contentsOf: self.sessionInfos(from: resolvedSources, origin: query.origin))
            } catch let error as BrowserCookieError {
                BrowserCookieAccessGate.recordIfNeeded(error)
                if let hint = error.accessDeniedHint {
                    accessDeniedHints.append(hint)
                }
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        log("Produced \(sessions.count) session(s) from \(installed.count) browser(s)")
        if sessions.isEmpty, !accessDeniedHints.isEmpty {
            let details = Array(Set(accessDeniedHints)).sorted().joined(separator: " ")
            throw MiMoSettingsError.missingCookie(details: details)
        }
        return sessions
    }

    static func recordsIncludingFirefoxSessionCookies(
        from sources: [BrowserCookieStoreRecords],
        browser: Browser,
        stores: [BrowserCookieStore],
        logger: ((String) -> Void)? = nil) -> [BrowserCookieStoreRecords]
    {
        guard browser.usesGeckoProfileStore else { return sources }

        var resolvedByProfileID = Dictionary(uniqueKeysWithValues: sources.map { ($0.store.profile.id, $0) })
        var orderedProfileIDs = sources.map(\.store.profile.id)

        for store in stores where store.browser == browser {
            let profileID = store.profile.id
            let source = resolvedByProfileID[profileID] ?? BrowserCookieStoreRecords(store: store, records: [])
            let profileDirectory = URL(fileURLWithPath: profileID, isDirectory: true)
            let sessionRecords = MiMoFirefoxSessionCookieImporter.records(
                profileDirectory: profileDirectory,
                persistedRecords: source.records,
                logger: logger)
            guard !sessionRecords.isEmpty else {
                if resolvedByProfileID[profileID] == nil {
                    continue
                }
                resolvedByProfileID[profileID] = source
                continue
            }

            let sessionKeys = Set(sessionRecords.map(self.recordKey))
            let persistedRecords = source.records.filter { !sessionKeys.contains(self.recordKey($0)) }
            logger?(
                "\(source.label): recovered \(sessionRecords.count) MiMo session cookie(s) " +
                    "from Firefox session restore")
            resolvedByProfileID[profileID] = BrowserCookieStoreRecords(
                store: source.store,
                records: persistedRecords + sessionRecords)

            if !orderedProfileIDs.contains(profileID) {
                orderedProfileIDs.append(profileID)
            }
        }

        return orderedProfileIDs.compactMap { resolvedByProfileID[$0] }
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? self.importSessions(browserDetection: browserDetection, logger: logger).isEmpty == false) ?? false
    }

    static func sessionInfos(
        from sources: [BrowserCookieStoreRecords],
        origin: BrowserCookieOriginStrategy = .domainBased) -> [SessionInfo]
    {
        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        let sortedGroups = grouped.values.sorted { lhs, rhs in
            self.mergedLabel(for: lhs) < self.mergedLabel(for: rhs)
        }

        var sessions: [SessionInfo] = []
        for group in sortedGroups where !group.isEmpty {
            let label = self.mergedLabel(for: group)
            let mergedRecords = self.mergeRecords(group)
            guard !mergedRecords.isEmpty else { continue }
            let cookies = BrowserCookieClient.makeHTTPCookies(mergedRecords, origin: origin)
            guard let cookieHeader = MiMoCookieHeader.header(from: cookies) else {
                let cookieNames = mergedRecords.map(\.name).joined(separator: ", ")
                let message = "\(label): \(mergedRecords.count) cookie(s) (\(cookieNames))"
                Self.log.debug("\(message) - missing required [api-platform_serviceToken, userId]")
                continue
            }
            sessions.append(SessionInfo(cookieHeader: cookieHeader, sourceLabel: label))
        }
        return sessions
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else {
            return "Unknown"
        }
        if base.hasSuffix(" (Network)") {
            return String(base.dropLast(" (Network)".count))
        }
        return base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted { lhs, rhs in
            self.storePriority(lhs.store.kind) < self.storePriority(rhs.store.kind)
        }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = self.recordKey(record)
                if let existing = mergedByKey[key] {
                    if self.shouldReplace(existing: existing, candidate: record) {
                        mergedByKey[key] = record
                    }
                } else {
                    mergedByKey[key] = record
                }
            }
        }
        return Array(mergedByKey.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func recordKey(_ record: BrowserCookieRecord) -> String {
        "\(record.name)|\(record.domain)|\(record.path)"
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?):
            rhs > lhs
        case (nil, .some):
            true
        case (.some, nil):
            false
        case (nil, nil):
            false
        }
    }
}

enum MiMoFirefoxSessionCookieImporter {
    enum ImportError: LocalizedError {
        case inputTooLarge
        case outputTooLarge
        case invalidData(String)

        var errorDescription: String? {
            switch self {
            case .inputTooLarge:
                "Firefox session restore file exceeds the 64 MiB safety limit."
            case .outputTooLarge:
                "Firefox session restore data exceeds the 128 MiB safety limit."
            case let .invalidData(message):
                message
            }
        }
    }

    private static let maxInputBytes = 64 * 1024 * 1024
    private static let maxOutputBytes = 128 * 1024 * 1024
    private static let maxJSONNodes = 1_000_000
    private static let maxCookieRecords = 4096
    private static let sessionRestoreFileNames = [
        "recovery.jsonlz4",
        "recovery.baklz4",
        "previous.jsonlz4",
        "sessionstore.jsonlz4",
    ]
    private static let mozillaLZ4Magic = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])

    static func records(
        profileDirectory: URL,
        persistedRecords: [BrowserCookieRecord] = [],
        now: Date = Date(),
        logger: ((String) -> Void)? = nil) -> [BrowserCookieRecord]
    {
        let files = self.sessionRestoreFiles(profileDirectory: profileDirectory)
        var firstPartialRecords: [BrowserCookieRecord] = []
        for file in files {
            do {
                let data = try self.readData(from: file)
                let jsonData = try self.decodeSessionRestoreData(data)
                let records = try self.cookieRecords(fromJSONData: jsonData, now: now)
                guard !records.isEmpty else { continue }
                let isCurrentRestore = file.lastPathComponent == "recovery.jsonlz4" ||
                    (file.lastPathComponent == "sessionstore.jsonlz4" &&
                        file.deletingLastPathComponent().standardizedFileURL == profileDirectory.standardizedFileURL)
                let persistedKeys = Set(persistedRecords.map { "\($0.name)|\($0.domain)|\($0.path)" })
                let candidateRecords = isCurrentRestore ? records : records.filter { record in
                    !persistedKeys.contains("\(record.name)|\(record.domain)|\(record.path)")
                }
                guard !candidateRecords.isEmpty else { continue }
                if firstPartialRecords.isEmpty {
                    firstPartialRecords = candidateRecords
                }
                let candidateKeys = Set(candidateRecords.map { "\($0.name)|\($0.domain)|\($0.path)" })
                let resolvedRecords = persistedRecords.filter { record in
                    !candidateKeys.contains("\(record.name)|\(record.domain)|\(record.path)")
                } + candidateRecords
                let cookies = BrowserCookieClient.makeHTTPCookies(resolvedRecords, origin: .domainBased)
                if MiMoCookieHeader.header(from: cookies) != nil {
                    logger?(
                        "\(profileDirectory.lastPathComponent): found MiMo session cookies through " +
                            "\(file.lastPathComponent)")
                    return candidateRecords
                }
                logger?("\(profileDirectory.lastPathComponent): partial MiMo cookies in \(file.lastPathComponent)")
            } catch {
                logger?(
                    "\(profileDirectory.lastPathComponent): could not read Firefox session restore " +
                        "\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return firstPartialRecords
    }

    static func readData(
        from file: URL,
        maxBytes: Int = MiMoFirefoxSessionCookieImporter.maxInputBytes) throws -> Data
    {
        guard maxBytes >= 0, maxBytes < Int.max else { throw ImportError.inputTooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw ImportError.inputTooLarge }
        return data
    }

    private static func sessionRestoreFiles(profileDirectory: URL) -> [URL] {
        let backupDirectory = profileDirectory.appendingPathComponent("sessionstore-backups", isDirectory: true)
        var files = self.sessionRestoreFileNames.map { backupDirectory.appendingPathComponent($0) }
        files.append(profileDirectory.appendingPathComponent("sessionstore.jsonlz4"))

        if let upgradeFiles = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            files.append(contentsOf: upgradeFiles.filter { $0.lastPathComponent.hasPrefix("upgrade.jsonlz4-") })
        }

        var seen = Set<String>()
        return files.filter { file in
            guard FileManager.default.fileExists(atPath: file.path), !seen.contains(file.path) else { return false }
            seen.insert(file.path)
            return true
        }
    }

    static func decodeSessionRestoreData(
        _ data: Data,
        maxOutputBytes: Int = MiMoFirefoxSessionCookieImporter.maxOutputBytes) throws -> Data
    {
        guard maxOutputBytes >= 0 else { throw ImportError.outputTooLarge }
        guard data.starts(with: self.mozillaLZ4Magic) else {
            guard data.count <= maxOutputBytes else { throw ImportError.outputTooLarge }
            return data
        }
        let payload = data.dropFirst(self.mozillaLZ4Magic.count)
        let directError: Error
        do {
            return try self.decodeLZ4Block(Data(payload), maxOutputBytes: maxOutputBytes)
        } catch {
            directError = error
            // Some jsonlz4 writers prefix the raw block with its decoded byte count.
        }
        guard payload.count > 4 else {
            throw directError
        }
        do {
            return try self.decodeLZ4Block(Data(payload.dropFirst(4)), maxOutputBytes: maxOutputBytes)
        } catch {
            if case ImportError.outputTooLarge = directError {
                throw ImportError.outputTooLarge
            }
            throw error
        }
    }

    static func cookieRecords(
        fromJSONData data: Data,
        now: Date = Date(),
        maxNodes: Int = MiMoFirefoxSessionCookieImporter.maxJSONNodes,
        maxRecords: Int = MiMoFirefoxSessionCookieImporter.maxCookieRecords) throws -> [BrowserCookieRecord]
    {
        let root = try JSONSerialization.jsonObject(with: data)
        var stack: [Any] = [root]
        var records: [BrowserCookieRecord] = []
        var visitedNodes = 0
        while let value = stack.popLast() {
            visitedNodes += 1
            guard visitedNodes <= maxNodes else {
                throw ImportError.invalidData("Firefox session restore JSON is too complex.")
            }
            if let dictionary = value as? [String: Any] {
                if let record = self.cookieRecord(from: dictionary, now: now) {
                    records.append(record)
                    guard records.count <= maxRecords else {
                        throw ImportError.invalidData("Firefox session restore contains too many cookie records.")
                    }
                }
                stack.append(contentsOf: dictionary.values)
            } else if let array = value as? [Any] {
                stack.append(contentsOf: array)
            }
        }
        return records
    }

    private static func cookieRecord(from dictionary: [String: Any], now: Date) -> BrowserCookieRecord? {
        guard let name = dictionary["name"] as? String,
              MiMoCookieHeader.knownCookieNames.contains(name),
              let value = dictionary["value"] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let host = (dictionary["host"] as? String) ?? (dictionary["domain"] as? String)
        else {
            return nil
        }

        let domain = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard self.domainMatchesMiMo(domain) else { return nil }

        let expiry = self.expiryDate(from: dictionary["expires"] ?? dictionary["expiry"])
        if let expiry, expiry < now { return nil }

        let path = self.cookiePath(from: dictionary)
        return BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: expiry,
            isSecure: dictionary["secure"] as? Bool ?? false,
            isHTTPOnly: (dictionary["httponly"] as? Bool) ?? (dictionary["httpOnly"] as? Bool) ?? false)
    }

    private static func cookiePath(from dictionary: [String: Any]) -> String {
        guard let path = dictionary["path"] as? String, !path.isEmpty else {
            return "/"
        }
        return path
    }

    private static func domainMatchesMiMo(_ domain: String) -> Bool {
        let lowercased = domain.lowercased()
        return lowercased == "xiaomimimo.com"
            || lowercased == "platform.xiaomimimo.com"
            || lowercased.hasSuffix(".xiaomimimo.com")
    }

    private static func expiryDate(from value: Any?) -> Date? {
        switch value {
        case let int as Int:
            guard int > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(int))
        case let int64 as Int64:
            guard int64 > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(int64))
        case let double as Double:
            guard double > 0 else { return nil }
            return Date(timeIntervalSince1970: double)
        default:
            return nil
        }
    }

    private static func decodeLZ4Block(_ input: Data, maxOutputBytes: Int) throws -> Data {
        let bytes = [UInt8](input)
        var index = 0
        var output: [UInt8] = []

        while index < bytes.count {
            let token = bytes[index]
            index += 1

            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                literalLength += try self.readExtendedLength(
                    bytes: bytes,
                    index: &index,
                    limit: maxOutputBytes - literalLength)
            }
            guard literalLength <= bytes.count - index else {
                throw ImportError.invalidData("Invalid LZ4 literal length.")
            }
            guard literalLength <= maxOutputBytes - output.count else { throw ImportError.outputTooLarge }
            output.append(contentsOf: bytes[index..<index + literalLength])
            index += literalLength

            guard index < bytes.count else { break }
            guard bytes.count - index >= 2 else {
                throw ImportError.invalidData("Invalid LZ4 offset.")
            }

            let offset = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
            guard offset > 0, offset <= output.count else {
                throw ImportError.invalidData("Invalid LZ4 back reference.")
            }

            var matchLength = Int(token & 0x0F) + 4
            if token & 0x0F == 15 {
                matchLength += try self.readExtendedLength(
                    bytes: bytes,
                    index: &index,
                    limit: maxOutputBytes - matchLength)
            }
            guard matchLength <= maxOutputBytes - output.count else { throw ImportError.outputTooLarge }

            for _ in 0..<matchLength {
                output.append(output[output.count - offset])
            }
        }

        return Data(output)
    }

    private static func readExtendedLength(bytes: [UInt8], index: inout Int, limit: Int) throws -> Int {
        var length = 0
        while index < bytes.count {
            let next = Int(bytes[index])
            index += 1
            guard length <= limit, next <= limit - length else { throw ImportError.outputTooLarge }
            length += next
            if next != 255 { break }
        }
        return length
    }
}
#endif
