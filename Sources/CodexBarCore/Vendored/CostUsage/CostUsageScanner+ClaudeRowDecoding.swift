import Foundation

/// One cache decode or transcript scan owns each pool.
final class ClaudeRowStringPool: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "claudeRowStringPool")!
    private let lock = NSLock()
    private var strings: [Data: String] = [:]

    func intern(_ value: String) -> String {
        self.lock.withLock {
            // String equality folds NFC/NFD spellings; artifact bytes must remain exact.
            let key = Data(value.utf8)
            if let existing = self.strings[key] { return existing }
            var shared = value
            shared.makeContiguousUTF8()
            self.strings[key] = shared
            return shared
        }
    }
}

extension CostUsageScanner.ClaudeUsageRow {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let pool = decoder.userInfo[ClaudeRowStringPool.key] as? ClaudeRowStringPool
        self.dayKey = try values.decode(String.self, forKey: .dayKey)
        let model = try values.decode(String.self, forKey: .model)
        self.model = pool?.intern(model) ?? model
        self.sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId).map { pool?.intern($0) ?? $0 }
        self.messageId = try values.decodeIfPresent(String.self, forKey: .messageId)
        self.requestId = try values.decodeIfPresent(String.self, forKey: .requestId)
        self.timestampUnixMs = try values.decodeIfPresent(Int64.self, forKey: .timestampUnixMs)
        self.isSidechain = try values.decode(Bool.self, forKey: .isSidechain)
        self.pathRole = try values.decode(CostUsageScanner.ClaudePathRole.self, forKey: .pathRole)
        self.input = try values.decode(Int.self, forKey: .input)
        self.cacheRead = try values.decode(Int.self, forKey: .cacheRead)
        self.cacheCreate = try values.decode(Int.self, forKey: .cacheCreate)
        self.cacheCreate1h = try values.decodeIfPresent(Int.self, forKey: .cacheCreate1h)
        self.output = try values.decode(Int.self, forKey: .output)
        self.costNanos = try values.decode(Int.self, forKey: .costNanos)
        self.costPriced = try values.decodeIfPresent(Bool.self, forKey: .costPriced)
        self.isIncomplete = try values.decodeIfPresent(Bool.self, forKey: .isIncomplete)
    }
}
