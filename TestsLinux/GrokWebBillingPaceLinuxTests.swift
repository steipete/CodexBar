import Foundation
import Testing
@testable import CodexBarCore

struct GrokWebBillingPaceLinuxTests {
    @Test
    func `web billing parses period length from start and end timestamps`() throws {
        let hex =
            "0a3f0d7f6a9c3f12001a002206088097f3d0062a060880b191d2063a07080215a9389b3f3a07080115d6ea183c" +
            "421208011206088097f3d0061a060880b191d206"
        let data = try #require(Self.data(hexString: hex))

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            data,
            now: Date(timeIntervalSince1970: 1_781_000_000))

        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_782_864_000))
        #expect(snapshot.windowMinutes == 30 * 24 * 60)
    }

    @Test
    func `rejects future preferred period start when deriving window length`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let futureStart = now.addingTimeInterval(86400)
        let resetsAt = now.addingTimeInterval(8 * 86400)
        let start = GrokWebBillingFetcher.billingPeriodStart(
            from: [
                (path: [1, 4, 1], date: futureStart),
                (path: [1, 5, 1], date: resetsAt),
            ],
            resetsAt: resetsAt,
            now: now)

        #expect(start == nil)
        #expect(GrokWebBillingFetcher.billingWindowMinutes(from: start, to: resetsAt) == nil)
    }

    @Test
    func `late cycle monthly window supports reset pace when duration is known`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 37,
            windowMinutes: 30 * 24 * 60,
            resetsAt: now.addingTimeInterval((2 * 24 + 9) * 3600),
            resetDescription: nil)
        let capability = GrokProviderDescriptor.descriptor.pace

        #expect(GrokProviderDescriptor.primaryLabel(window: window, now: now) == "Monthly")
        #expect(capability.supportsResetWindowPace(window: window, now: now))
    }

    @Test
    func `late cycle weekly window supports reset pace when duration is known`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 37,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval((2 * 24 + 9) * 3600),
            resetDescription: nil)
        let capability = GrokProviderDescriptor.descriptor.pace

        #expect(GrokProviderDescriptor.primaryLabel(window: window, now: now) == "Weekly")
        #expect(capability.supportsResetWindowPace(window: window, now: now))
    }

    @Test
    func `unclassified short reset without duration still skips pace`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 37,
            windowMinutes: nil,
            resetsAt: now.addingTimeInterval((2 * 24 + 9) * 3600),
            resetDescription: nil)
        let capability = GrokProviderDescriptor.descriptor.pace

        #expect(GrokProviderDescriptor.primaryLabel(window: window, now: now) == nil)
        #expect(!capability.supportsResetWindowPace(window: window, now: now))
    }

    private static func data(hexString: String) -> Data? {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard next > index,
                  let byte = UInt8(hexString[index..<next], radix: 16)
            else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
