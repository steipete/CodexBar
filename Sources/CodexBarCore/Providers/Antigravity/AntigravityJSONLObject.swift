import Foundation

/// Keep the provider's exact-number and duplicate-key contract over the shared lexer.
enum AntigravityJSONLObject {
    typealias Number = LosslessJSONLObject.Number

    static func decode(_ bytes: [UInt8], checkCancellation: @escaping () throws -> Void) throws -> [String: Any]? {
        guard let decoded = try LosslessJSONLObject.decode(bytes, checkCancellation: checkCancellation),
              !decoded.hasDuplicateKeys, var object = decoded.object as? [String: Any] else { return nil }
        for (key, number) in decoded.numbers[[]] ?? [:] {
            object[key] = number
        }
        return object
    }
}
