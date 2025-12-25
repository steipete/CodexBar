#if os(macOS)
import Foundation

/// Reads cookies from Safari's `Cookies.binarycookies` file (macOS).
///
/// This is a best-effort parser for the documented `binarycookies` format:
/// file header is big-endian; cookie pages and records are little-endian.
enum SafariCookieImporter {
    enum ImportError: LocalizedError {
        case cookieFileNotFound
        case cookieFileNotReadable(path: String)
        case invalidFile

        var errorDescription: String? {
            switch self {
            case .cookieFileNotFound: "Safari cookie file not found."
            case let .cookieFileNotReadable(path):
                "Safari cookie file exists but is not readable (\(path)). Enable Full Disk Access for CodexBar."
            case .invalidFile: "Safari cookie file is invalid."
            }
        }
    }

    struct CookieRecord: Sendable {
        let domain: String
        let name: String
        let path: String
        let value: String
        let expires: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
    }

    static func loadChatGPTCookies(logger: ((String) -> Void)? = nil) throws -> [CookieRecord] {
        try self.loadCookies(matchingDomains: ["chatgpt.com", "openai.com"], logger: logger)
    }

    static func loadChatGPTCookies() throws -> [CookieRecord] {
        try self.loadChatGPTCookies(logger: nil)
    }

    /// Loads cookies from Safari matching the given domains.
    /// - Parameters:
    ///   - domains: Array of domain patterns to match (e.g., ["claude.ai"])
    ///   - logger: Optional logging closure for debugging
    /// - Returns: Array of matching cookie records
    static func loadCookies(
        matchingDomains domains: [String],
        logger: ((String) -> Void)? = nil) throws -> [CookieRecord]
    {
        let candidates = self.candidateCookieFiles()
        var lastNoPermission: String?
        var lastReadError: String?

        for url in candidates {
            do {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
                logger?("Safari cookies: trying \(url.path) (\(size ?? -1) bytes)")
                let data = try Data(contentsOf: url)
                let records = try Self.parseBinaryCookies(data: data)
                return records.filter { record in
                    let d = record.domain.lowercased()
                    return domains.contains { d.contains($0.lowercased()) }
                }
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                lastNoPermission = url.path
                logger?("Safari cookies: permission denied for \(url.path)")
                continue
            } catch {
                lastReadError = "\(url.path): \(error.localizedDescription)"
                logger?("Safari cookies: failed to read \(url.path): \(error.localizedDescription)")
                continue
            }
        }

        if let lastNoPermission {
            throw ImportError.cookieFileNotReadable(path: lastNoPermission)
        }
        if let lastReadError {
            logger?("Safari cookies: last error: \(lastReadError)")
        }
        throw ImportError.cookieFileNotFound
    }

    static func makeHTTPCookies(_ records: [CookieRecord]) -> [HTTPCookie] {
        records.compactMap { record in
            let domain = Self.normalizeDomain(record.domain)
            guard !domain.isEmpty else { return nil }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: record.path,
                .name: record.name,
                .value: record.value,
                .secure: record.isSecure,
            ]
            props[.originURL] = Self.originURL(forDomain: domain)
            if record.isHTTPOnly {
                props[.init("HttpOnly")] = "TRUE"
            }
            if let expires = record.expires {
                props[.expires] = expires
            }
            return HTTPCookie(properties: props)
        }
    }

    // MARK: - BinaryCookies parsing

    private static func parseBinaryCookies(data: Data) throws -> [CookieRecord] {
        let reader = DataReader(data)
        guard reader.readASCII(count: 4) == "cook" else { throw ImportError.invalidFile }
        let pageCount = Int(reader.readUInt32BE())
        guard pageCount >= 0 else { throw ImportError.invalidFile }

        var pageSizes: [Int] = []
        pageSizes.reserveCapacity(pageCount)
        for _ in 0..<pageCount {
            pageSizes.append(Int(reader.readUInt32BE()))
        }

        var records: [CookieRecord] = []
        var offset = reader.offset
        for size in pageSizes {
            guard offset + size <= data.count else { throw ImportError.invalidFile }
            let pageData = data.subdata(in: offset..<(offset + size))
            records.append(contentsOf: Self.parsePage(data: pageData))
            offset += size
        }
        return records
    }

    private static func parsePage(data: Data) -> [CookieRecord] {
        let r = DataReader(data)
        _ = r.readUInt32LE() // page header
        let cookieCount = Int(r.readUInt32LE())
        if cookieCount <= 0 { return [] }

        var cookieOffsets: [Int] = []
        cookieOffsets.reserveCapacity(cookieCount)
        for _ in 0..<cookieCount {
            cookieOffsets.append(Int(r.readUInt32LE()))
        }

        return cookieOffsets.compactMap { offset in
            guard offset >= 0, offset + 56 <= data.count else { return nil }
            return Self.parseCookieRecord(data: data, offset: offset)
        }
    }

    private static func parseCookieRecord(data: Data, offset: Int) -> CookieRecord? {
        let r = DataReader(data, offset: offset)
        let size = Int(r.readUInt32LE())
        guard size > 0, offset + size <= data.count else { return nil }

        _ = r.readUInt32LE() // unknown
        let flags = r.readUInt32LE()
        _ = r.readUInt32LE() // unknown

        let urlOffset = Int(r.readUInt32LE())
        let nameOffset = Int(r.readUInt32LE())
        let pathOffset = Int(r.readUInt32LE())
        let valueOffset = Int(r.readUInt32LE())
        _ = r.readUInt32LE() // commentOffset
        _ = r.readUInt32LE() // commentURL

        let expiresRef = r.readDoubleLE()
        _ = r.readDoubleLE() // creation

        let domain = Self.readCString(data: data, base: offset, offset: urlOffset) ?? ""
        let name = Self.readCString(data: data, base: offset, offset: nameOffset) ?? ""
        let path = Self.readCString(data: data, base: offset, offset: pathOffset) ?? "/"
        let value = Self.readCString(data: data, base: offset, offset: valueOffset) ?? ""

        if domain.isEmpty || name.isEmpty { return nil }

        let isSecure = (flags & 0x1) != 0
        let isHTTPOnly = (flags & 0x4) != 0
        let expires = expiresRef > 0 ? Date(timeIntervalSinceReferenceDate: expiresRef) : nil

        return CookieRecord(
            domain: Self.normalizeDomain(domain),
            name: name,
            path: path,
            value: value,
            expires: expires,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly)
    }

    private static func readCString(data: Data, base: Int, offset: Int) -> String? {
        let start = base + offset
        guard start >= 0, start < data.count else { return nil }
        let end = data[start...].firstIndex(of: 0) ?? data.count
        guard end > start else { return nil }
        return String(data: data.subdata(in: start..<end), encoding: .utf8)
    }

    private static func normalizeDomain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return String(trimmed.dropFirst()) }
        return trimmed
    }

    private static func originURL(forDomain domain: String) -> URL {
        let d = domain.lowercased()
        if d.contains("openai.com") {
            return URL(string: "https://openai.com")!
        }
        return URL(string: "https://chatgpt.com")!
    }

    private static func candidateCookieFiles() -> [URL] {
        let homes = self.candidateHomes()
        var urls: [URL] = []
        urls.reserveCapacity(homes.count * 2)
        for home in homes {
            urls.append(home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"))
            urls.append(
                home.appendingPathComponent(
                    "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"))
        }
        // De-dup by path while keeping ordering (homeDirectoryForCurrentUser first).
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func candidateHomes() -> [URL] {
        var homes: [URL] = []
        homes.append(FileManager.default.homeDirectoryForCurrentUser)
        if let userHome = NSHomeDirectoryForUser(NSUserName()) {
            homes.append(URL(fileURLWithPath: userHome))
        }
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            homes.append(URL(fileURLWithPath: envHome))
        }
        // De-dup by path while keeping ordering.
        var seen = Set<String>()
        return homes.filter { home in
            let path = home.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}
#endif

// MARK: - DataReader

private final class DataReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    func readASCII(count: Int) -> String? {
        let d = self.read(count)
        return String(data: d, encoding: .ascii)
    }

    func read(_ count: Int) -> Data {
        let end = min(self.offset + count, self.data.count)
        let slice = self.data[self.offset..<end]
        self.offset = end
        return Data(slice)
    }

    func readUInt32BE() -> UInt32 {
        let d = self.read(4)
        return d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    func readUInt32LE() -> UInt32 {
        let d = self.read(4)
        return d.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    func readDoubleLE() -> Double {
        let d = self.read(8)
        let raw = d.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        return Double(bitPattern: raw)
    }
}
