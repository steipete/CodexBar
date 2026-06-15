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
                let resolvedSources = self.recordsIncludingFirefoxSessionCookies(from: sources, logger: log)
                let recordCount = sources.reduce(0) { $0 + $1.records.count }
                let resolvedRecordCount = resolvedSources.reduce(0) { $0 + $1.records.count }
                if resolvedRecordCount == recordCount {
                    log("\(browserSource.displayName): \(sources.count) store(s), \(recordCount) record(s)")
                } else {
                    log(
                        "\(browserSource.displayName): \(sources.count) store(s), " +
                            "\(recordCount) persisted record(s), \(resolvedRecordCount) record(s) after session restore")
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
        logger: ((String) -> Void)? = nil) -> [BrowserCookieStoreRecords]
    {
        sources.map { source in
            guard source.store.browser.usesGeckoProfileStore else { return source }
            let profileDirectory = URL(fileURLWithPath: source.store.profile.id, isDirectory: true)
            let sessionRecords = MiMoFirefoxSessionCookieImporter.records(
                profileDirectory: profileDirectory,
                logger: logger)
            guard !sessionRecords.isEmpty else { return source }

            let existingKeys = Set(source.records.map(self.recordKey))
            let additionalRecords = sessionRecords.filter { !existingKeys.contains(self.recordKey($0)) }
            guard !additionalRecords.isEmpty else { return source }
            logger?(
                "\(source.label): recovered \(additionalRecords.count) MiMo session cookie(s) " +
                    "from Firefox session restore")
            return BrowserCookieStoreRecords(store: source.store, records: source.records + additionalRecords)
        }
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
    private static let sessionRestoreFileNames = [
        "recovery.jsonlz4",
        "recovery.baklz4",
        "previous.jsonlz4",
        "sessionstore.jsonlz4",
    ]
    private static let mozillaLZ4Magic = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])

    static func records(
        profileDirectory: URL,
        now: Date = Date(),
        logger: ((String) -> Void)? = nil) -> [BrowserCookieRecord]
    {
        let files = self.sessionRestoreFiles(profileDirectory: profileDirectory)
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let jsonData = try self.decodeSessionRestoreData(data)
                let records = try self.cookieRecords(fromJSONData: jsonData, now: now)
                if !records.isEmpty {
                    logger?("\(profileDirectory.lastPathComponent): found MiMo session cookies in \(file.lastPathComponent)")
                    return records
                }
            } catch {
                logger?(
                    "\(profileDirectory.lastPathComponent): could not read Firefox session restore " +
                        "\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return []
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

    static func decodeSessionRestoreData(_ data: Data) throws -> Data {
        guard data.starts(with: self.mozillaLZ4Magic) else { return data }
        let payload = data.dropFirst(self.mozillaLZ4Magic.count)
        if let decoded = try? self.decodeLZ4Block(Data(payload)) {
            return decoded
        }
        guard payload.count > 4 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Firefox jsonlz4 data"))
        }
        return try self.decodeLZ4Block(Data(payload.dropFirst(4)))
    }

    static func cookieRecords(fromJSONData data: Data, now: Date = Date()) throws -> [BrowserCookieRecord] {
        let root = try JSONSerialization.jsonObject(with: data)
        var records: [BrowserCookieRecord] = []
        self.collectCookieRecords(from: root, into: &records, now: now)
        return records
    }

    private static func collectCookieRecords(
        from value: Any,
        into records: inout [BrowserCookieRecord],
        now: Date)
    {
        if let dictionary = value as? [String: Any] {
            if let record = self.cookieRecord(from: dictionary, now: now) {
                records.append(record)
            }
            for nested in dictionary.values {
                self.collectCookieRecords(from: nested, into: &records, now: now)
            }
            return
        }

        if let array = value as? [Any] {
            for nested in array {
                self.collectCookieRecords(from: nested, into: &records, now: now)
            }
        }
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

    private static func decodeLZ4Block(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        var index = 0
        var output: [UInt8] = []

        while index < bytes.count {
            let token = bytes[index]
            index += 1

            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                literalLength += self.readExtendedLength(bytes: bytes, index: &index)
            }
            guard index + literalLength <= bytes.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid LZ4 literal length"))
            }
            output.append(contentsOf: bytes[index ..< index + literalLength])
            index += literalLength

            guard index < bytes.count else { break }
            guard index + 2 <= bytes.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid LZ4 offset"))
            }

            let offset = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
            guard offset > 0, offset <= output.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid LZ4 back reference"))
            }

            var matchLength = Int(token & 0x0F) + 4
            if token & 0x0F == 15 {
                matchLength += self.readExtendedLength(bytes: bytes, index: &index)
            }

            for _ in 0 ..< matchLength {
                output.append(output[output.count - offset])
            }
        }

        return Data(output)
    }

    private static func readExtendedLength(bytes: [UInt8], index: inout Int) -> Int {
        var length = 0
        while index < bytes.count {
            let next = Int(bytes[index])
            index += 1
            length += next
            if next != 255 { break }
        }
        return length
    }
}
#endif
