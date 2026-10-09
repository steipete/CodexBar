import Foundation
import Testing
@testable import CodexBarCore

struct JetBrainsQuotaLogReaderTests {
    private static let olderQuotaLine =
        "2026-10-05 15:06:48,538 [1828154]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
            + "Available(current=300000, maximum=6489986.397, until=2028-09-22T21:00:00Z, "
            + "tariffQuota=QuotaDetails(current=300000, maximum=1000000, available=700000), "
            + "topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397))"
    private static let latestQuotaLine =
        "2026-10-05 15:27:49,811 [   8326]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
            + "Available(current=346495.294, maximum=6489986.397, until=2028-09-22T21:00:00Z, "
            + "tariffQuota=QuotaDetails(current=346495.294, maximum=1000000, available=653504.706), "
            + "topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397))"
    private static let refillLine =
        "2026-10-05 15:21:27,386 [2707002]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota refill state is: "
            + "Known(next=2026-10-11T17:00:30.231Z, tariff=QuotaRefillInfoTariff(amount=1000000, duration=30d))"

    private static func localDate(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return formatter.date(from: text)!
    }

    @Test(arguments: ["malformed", "truncated", "changed", "nonfinite", "unknown"])
    func `invalid latest quota falls back to XML instead of older log or total balance`(kind: String) throws {
        let line: String = switch kind {
        case "malformed":
            Self.latestQuotaLine.replacingOccurrences(
                of: "tariffQuota=QuotaDetails(current=346495.294", with: "tariffQuota=QuotaDetails(current=346..495")
        case "truncated":
            try String(Self.latestQuotaLine.prefix(through: #require(Self.latestQuotaLine.firstIndex(of: "("))))
                + "current=346495.294, maximum=6489986.397"
        case "changed":
            Self.latestQuotaLine.replacingOccurrences(
                of: "tariffQuota=QuotaDetails(current=", with: "tariffQuota=QuotaDetails(spent=")
        case "nonfinite":
            Self.latestQuotaLine.replacingOccurrences(of: "maximum=1000000", with: "maximum=1e999")
        default:
            Self.latestQuotaLine.components(separatedBy: "Available(")[0] + "Unknown"
        }
        let entry = JetBrainsQuotaLogReader.latestEntry(inLogContent: Self.olderQuotaLine + "\n" + line)
        #expect(entry == nil)
        let xml = JetBrainsStatusSnapshot(
            quotaInfo: .init(type: "Available", used: 25, maximum: 100, available: 75, until: nil),
            refillInfo: nil,
            detectedIDE: nil)
        #expect(JetBrainsStatusProbe.applyingLogEntry(
            entry, to: xml, quotaFileModifiedAt: .distantPast).quotaInfo == xml.quotaInfo)
    }

    @Test
    func `tail stops at captured file size even when the file grows`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("unrelated\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024))
        try handle.write(contentsOf: Data(("\n" + Self.latestQuotaLine + "\n").utf8))

        let tail = try #require(JetBrainsQuotaLogReader.readTail(from: handle, endOffset: end))
        #expect(tail.utf8.count <= end)
        #expect(tail.utf8.count <= JetBrainsQuotaLogReader.tailByteCount)
        #expect(JetBrainsQuotaLogReader.latestEntry(inLogContent: tail) == nil)
    }

    @Test
    func `log snapshot does not borrow XML refill without account proof`() throws {
        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: Self.latestQuotaLine))
        let xml = JetBrainsStatusSnapshot(
            quotaInfo: entry.quotaInfo,
            refillInfo: .init(type: "Known", next: .distantFuture, amount: 100, duration: "30d"),
            detectedIDE: nil)
        let snapshot = JetBrainsStatusProbe.applyingLogEntry(entry, to: xml, quotaFileModifiedAt: .distantPast)
        #expect(snapshot.refillInfo == nil)
    }

    @Test
    func `parses latest quota and refill state from idea log`() throws {
        let log = [
            "2026-10-05 15:00:00,000 [1]   INFO - #c.i.p.i.b.AppStarter - IDE STARTED",
            Self.olderQuotaLine,
            Self.refillLine,
            Self.latestQuotaLine,
            "2026-10-05 15:30:00,000 [2]   INFO - #c.i.o.SomethingElse - unrelated",
        ].joined(separator: "\n")

        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: log))

        #expect(entry.timestamp == Self.localDate("2026-10-05 15:27:49,811"))
        #expect(entry.quotaInfo.type == "Available")
        #expect(entry.quotaInfo.used == 346_495.294)
        #expect(entry.quotaInfo.maximum == 1_000_000)
        #expect(entry.quotaInfo.available == 653_504.706)
        #expect(abs(entry.quotaInfo.remainingPercent - 65.3504706) < 0.0001)
        #expect(entry.quotaInfo.until == ISO8601DateParser.parse("2028-09-22T21:00:00Z"))
        #expect(entry.refillInfo?.type == "Known")
        #expect(entry.refillInfo?.next == ISO8601DateParser.parse("2026-10-11T17:00:30.231Z"))
        #expect(entry.refillInfo?.amount == 1_000_000)
        #expect(entry.refillInfo?.duration == "30d")
        #expect(entry.quotaInfo.topUp == JetBrainsTopUpQuota(maximum: 5_489_986.397, available: 5_489_986.397))
        #expect(abs((entry.quotaInfo.topUp?.availableCredits ?? 0) - 54.89986397) < 0.0001)
    }

    @Test
    func `quota state without top-up group has no top-up credits`() throws {
        let line =
            "2026-10-05 15:27:49,811 [   8326]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
                + "Available(current=346495.294, maximum=1000000, until=2028-09-22T21:00:00Z, "
                + "tariffQuota=QuotaDetails(current=346495.294, maximum=1000000, available=653504.706))"

        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: line))

        #expect(entry.quotaInfo.available == 653_504.706)
        #expect(entry.quotaInfo.topUp == nil)
    }

    @Test
    func `unknown latest quota invalidates previous quota`() {
        let unknownLine =
            "2026-10-05 15:40:00,000 [9000]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: Unknown"
        let log = [Self.latestQuotaLine, unknownLine].joined(separator: "\n")

        #expect(JetBrainsQuotaLogReader.latestEntry(inLogContent: log) == nil)
    }

    @Test
    func `returns nil when the log has no quota state`() {
        let log = "2026-10-05 15:00:00,000 [1]   INFO - #c.i.p.i.b.AppStarter - IDE STARTED"
        #expect(JetBrainsQuotaLogReader.latestEntry(inLogContent: log) == nil)
    }

    @Test
    func `maps IDE config directory to its log file`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        let path = JetBrainsQuotaLogReader.logFilePath(
            forIDEBasePath: "\(home)/Library/Application Support/JetBrains/DataGrip2026.2")
        #expect(path == "\(home)/Library/Logs/JetBrains/DataGrip2026.2/idea.log")
        #else
        let path = JetBrainsQuotaLogReader.logFilePath(forIDEBasePath: "\(home)/.config/JetBrains/DataGrip2026.2")
        #expect(path == "\(home)/.cache/JetBrains/DataGrip2026.2/log/idea.log")
        #endif
    }

    @Test
    func `prefers log entry newer than the persisted quota file`() throws {
        let staleSnapshot = JetBrainsStatusSnapshot(
            quotaInfo: JetBrainsQuotaInfo(
                type: "Available",
                used: 68433.145,
                maximum: 1_000_000,
                available: 931_566.855,
                until: nil),
            refillInfo: nil,
            detectedIDE: nil)
        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(
            inLogContent: [Self.refillLine, Self.latestQuotaLine].joined(separator: "\n")))

        let fresh = JetBrainsStatusProbe.applyingLogEntry(
            entry,
            to: staleSnapshot,
            quotaFileModifiedAt: Self.localDate("2026-09-22 15:11:35,000"))
        #expect(fresh.quotaInfo.available == 653_504.706)
        #expect(fresh.refillInfo?.next == ISO8601DateParser.parse("2026-10-11T17:00:30.231Z"))

        let kept = JetBrainsStatusProbe.applyingLogEntry(
            entry,
            to: staleSnapshot,
            quotaFileModifiedAt: Self.localDate("2026-10-05 16:00:00,000"))
        #expect(kept.quotaInfo.available == 931_566.855)
    }

    @Test
    func `custom config copies cannot borrow installed IDE logs`() {
        #expect(JetBrainsQuotaLogReader.logFilePath(forIDEBasePath: "/copy/JetBrains/DataGrip2026.2") == nil)
        #expect(JetBrainsQuotaLogReader.logFilePath(forIDEBasePath: "/copy/Google/AndroidStudio2026.2") == nil)
    }

    @Test
    func `tail discards a split UTF8 prefix and keeps complete quota records`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let suffix = Data(("\n" + Self.latestQuotaLine + "\n").utf8)
        let cap = Int(JetBrainsQuotaLogReader.tailByteCount)
        var data = Data(repeating: UInt8(ascii: "x"), count: cap)
        data.append(contentsOf: [0xF0, 0x9F, 0xA6, 0x9E])
        data.append(Data(repeating: UInt8(ascii: "x"), count: cap - suffix.count - 3))
        data.append(suffix)
        try data.write(to: url)
        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(atPath: url.path))
        #expect(entry.quotaInfo.used == 346_495.294)
        #expect(entry.quotaInfo.maximum == 1_000_000)
    }

    @Test
    func `quota outside the tail and incomplete final writes are ignored`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data((Self.latestQuotaLine + "\n").utf8)
        data.append(Data(repeating: UInt8(ascii: "x"), count: Int(JetBrainsQuotaLogReader.tailByteCount)))
        data.append(UInt8(ascii: "\n"))
        try data.write(to: url)
        #expect(JetBrainsQuotaLogReader.latestEntry(atPath: url.path) == nil)
        try Data((Self.olderQuotaLine + "\n" + Self.latestQuotaLine).utf8).write(to: url)
        #expect(JetBrainsQuotaLogReader.latestEntry(atPath: url.path) == nil)
        try Data([0xFF, 0x0A]).write(to: url)
        #expect(JetBrainsQuotaLogReader.latestEntry(atPath: url.path) == nil)
    }

    @Test
    func `latest malformed refill does not resurrect an older reset`() throws {
        let malformed = Self.refillLine.replacingOccurrences(of: "amount=1000000", with: "amount=1..0")
        let log = [Self.refillLine, Self.latestQuotaLine, malformed].joined(separator: "\n")
        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: log))
        #expect(entry.refillInfo == nil)
    }

    @Test
    func `unknown quota boundary prevents carrying a previous refill forward`() throws {
        let unknown = Self.olderQuotaLine.components(separatedBy: "Available(")[0] + "Unknown"
        let log = [Self.refillLine, unknown, Self.latestQuotaLine].joined(separator: "\n")
        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: log))
        #expect(entry.refillInfo == nil)
    }

    @Test
    func `missing XML modification date preserves the XML source`() throws {
        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: Self.latestQuotaLine))
        let xml = JetBrainsStatusSnapshot(
            quotaInfo: .init(type: "Available", used: 25, maximum: 100, available: 75, until: nil),
            refillInfo: nil,
            detectedIDE: nil)
        #expect(JetBrainsStatusProbe.applyingLogEntry(entry, to: xml, quotaFileModifiedAt: nil).quotaInfo == xml
            .quotaInfo)
        #expect(JetBrainsStatusProbe.applyingLogEntry(
            entry, to: xml, quotaFileModifiedAt: entry.timestamp).quotaInfo == xml.quotaInfo)
    }
}
