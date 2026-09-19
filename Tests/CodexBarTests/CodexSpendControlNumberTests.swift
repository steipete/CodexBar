import Foundation
import Testing
@testable import CodexBarCore

struct CodexSpendControlNumberTests {
    @Test(arguments: [
        ("1782864000", 1_782_864_000),
        ("1782864000.9", 1_782_864_000),
        ("-1.9", -1),
        (#"" 1782864000 ""#, 1_782_864_000),
        ("9223372036854775808", nil),
        ("1e100", nil),
        ("-1e100", nil),
        ("null", nil),
        ("true", nil),
    ] as [(String, Int?)])
    func `spend reset parsing preserves truncation and rejects unrepresentable counts`(
        raw: String, expected: Int?) throws
    {
        let payload = Data("{\"reset_at\":\(raw),\"limit\":\" 100 \",\"used\":12.5}".utf8)
        let snapshot = try JSONDecoder().decode(CodexUsageResponse.SpendControlLimitSnapshot.self, from: payload)
        #expect(snapshot.resetsAt == expected)
        #expect(snapshot.limit == 100)
        #expect(snapshot.used == 12.5)
    }
}
