import Foundation
import SweetCookieKit

#if os(macOS)

enum BinaryCookiesReader {
    enum ReadError: LocalizedError {
        case fileNotFound
        case fileNotReadable(path: String)
        case invalidFile

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                "Cookie file not found."
            case let .fileNotReadable(path):
                "Cookie file exists but is not readable (\(path))."
            case .invalidFile:
                "Cookie file is invalid."
            }
        }
    }

    struct Record: Sendable {
        let domain: String
        let name: String
        let path: String
        let value: String
        let expires: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
    }

    static func loadCookies(
        from url: URL,
        matching query: BrowserCookieQuery,
        logger: ((String) -> Void)? = nil) throws -> [Record]
    {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.fileNotFound
        }

        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            logger?("Binary cookies: trying \(url.path) (\(size ?? -1) bytes)")
            let data = try Data(contentsOf: url)
            let records = try Self.parseBinaryCookies(data: data)
            return Self.filter(records: records, matching: query)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ReadError.fileNotReadable(path: url.path)
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.invalidFile
        }
    }

    private static func filter(records: [Record], matching query: BrowserCookieQuery) -> [Record] {
        let now = query.referenceDate
        return records.filter { record in
            if !query.includeExpired, let expires = record.expires, expires <= now {
                return false
            }
            if query.domains.isEmpty { return true }
            return Self.matches(domain: record.domain, patterns: query.domains, match: query.domainMatch)
        }
    }

    private static func matches(domain: String, patterns: [String], match: BrowserCookieDomainMatch) -> Bool {
        let normalized = Self.normalizeDomain(domain).lowercased()
        for pattern in patterns {
            let needle = Self.normalizeDomain(pattern).lowercased()
            switch match {
            case .contains:
                if normalized.contains(needle) { return true }
            case .suffix:
                if normalized.hasSuffix(needle) { return true }
            case .exact:
                if normalized == needle { return true }
            }
        }
        return false
    }

    private static func normalizeDomain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return String(trimmed.dropFirst()) }
        return trimmed
    }

    // MARK: - BinaryCookies parsing

    private static func parseBinaryCookies(data: Data) throws -> [Record] {
        let reader = DataReader(data)
        guard reader.readASCII(count: 4) == "cook" else { throw ReadError.invalidFile }
        let pageCount = Int(reader.readUInt32BE())
        guard pageCount >= 0 else { throw ReadError.invalidFile }

        var pageSizes: [Int] = []
        pageSizes.reserveCapacity(pageCount)
        for _ in 0..<pageCount {
            pageSizes.append(Int(reader.readUInt32BE()))
        }

        var records: [Record] = []
        var offset = reader.offset
        for size in pageSizes {
            guard offset + size <= data.count else { throw ReadError.invalidFile }
            let pageData = data.subdata(in: offset..<(offset + size))
            records.append(contentsOf: Self.parsePage(data: pageData))
            offset += size
        }
        return records
    }

    private static func parsePage(data: Data) -> [Record] {
        let reader = DataReader(data)
        _ = reader.readUInt32LE()
        let cookieCount = Int(reader.readUInt32LE())
        if cookieCount <= 0 { return [] }

        var cookieOffsets: [Int] = []
        cookieOffsets.reserveCapacity(cookieCount)
        for _ in 0..<cookieCount {
            cookieOffsets.append(Int(reader.readUInt32LE()))
        }

        return cookieOffsets.compactMap { offset in
            guard offset >= 0, offset + 56 <= data.count else { return nil }
            return Self.parseCookieRecord(data: data, offset: offset)
        }
    }

    private static func parseCookieRecord(data: Data, offset: Int) -> Record? {
        let reader = DataReader(data, offset: offset)
        let size = Int(reader.readUInt32LE())
        guard size > 0, offset + size <= data.count else { return nil }

        _ = reader.readUInt32LE()
        let flags = reader.readUInt32LE()
        _ = reader.readUInt32LE()

        let urlOffset = Int(reader.readUInt32LE())
        let nameOffset = Int(reader.readUInt32LE())
        let pathOffset = Int(reader.readUInt32LE())
        let valueOffset = Int(reader.readUInt32LE())
        _ = reader.readUInt32LE()
        _ = reader.readUInt32LE()

        let expiresRef = reader.readDoubleLE()
        _ = reader.readDoubleLE()

        let domain = Self.readCString(data: data, base: offset, offset: urlOffset) ?? ""
        let name = Self.readCString(data: data, base: offset, offset: nameOffset) ?? ""
        let path = Self.readCString(data: data, base: offset, offset: pathOffset) ?? "/"
        let value = Self.readCString(data: data, base: offset, offset: valueOffset) ?? ""

        if domain.isEmpty || name.isEmpty { return nil }

        let isSecure = (flags & 0x1) != 0
        let isHTTPOnly = (flags & 0x4) != 0
        let expires = expiresRef > 0 ? Date(timeIntervalSinceReferenceDate: expiresRef) : nil

        return Record(
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
}

private final class DataReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    func readASCII(count: Int) -> String? {
        let chunk = self.read(count)
        return String(data: chunk, encoding: .ascii)
    }

    func read(_ count: Int) -> Data {
        let end = min(self.offset + count, self.data.count)
        let slice = self.data[self.offset..<end]
        self.offset = end
        return Data(slice)
    }

    func readUInt32BE() -> UInt32 {
        let chunk = self.read(4)
        return chunk.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    func readUInt32LE() -> UInt32 {
        let chunk = self.read(4)
        return chunk.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    func readDoubleLE() -> Double {
        let chunk = self.read(8)
        let raw = chunk.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        return Double(bitPattern: raw)
    }
}

#endif
